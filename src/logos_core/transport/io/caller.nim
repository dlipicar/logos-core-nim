## TRANSPORT §3.1, §3.2, §3.4, §4, §5.1, §6, §8.2, §8.6, §9.1; RUNTIME §4.1: the
## caller side on the I/O thread. Connect to exactly the path given, check the
## peer's identity before writing any byte, send the Hello with the one-time
## ticket, check the answer, then run the established `CallerConn`: calls,
## subscriptions, and Events handed to the owner under credits.
##
## Credits [IMPL]: an Event's frame stays reserved in the input pool, and
## counts against the connection's `callerUndeliveredBytes`, from `evEvent`
## until the owner's `cmdRelease`. At the budget reading pauses; it never
## drops. Responses are bounded by the calls the owner made (`maxCalls`,
## `maxTotalCalls`) and need no credit.

{.push raises: [], gcsafe.}

import chronos/asyncloop
import results
import ../../cbor
import ../../iface/[outcome, surface]
import ../[boundary, envelope, hello, session]
import ./[api, conn, peercred, sock]

type Outcome = outcome.Outcome ## `commitment/choice` exports another `Outcome`

const ConnectRetry = 10_000_000'i64
  ## [IMPL] 10 ms between attempts while the listener's backlog is full

proc fail(code: ErrorCode, cause: ConnectFailure, msg: string): Opt[ConnectFail] =
  Opt.some(ConnectFail(code: code, cause: cause, msg: msg))

proc failNow(io: Io, id: ConnId, code: ErrorCode, cause: ConnectFailure, msg: string) =
  ## A connect refused before anything was opened.
  io.emit(
    IoEvent(
      conn: id, kind: evConnectFailed, failCode: code, failCause: cause, failMsg: msg
    )
  )

proc selectedBoundary(io: Io, input: ContractInput): Result[Boundary, string] =
  ## The route's selected contract, rebuilt on this thread from the
  ## construction input `materialize_route` validated (§3.1), and cached.
  var b: Boundary
  if io.selected.pop(input.root, b):
    io.selected[input.root] = b
    return ok(b)
  let set =
    ?acceptSchemaResponse(input.schema, input.root, AcceptOptions(system: input.system))
  b = ?boundary(set, input.root)
  io.selected[input.root] = b
  ok(b)

proc tryConnect(io: Io, c: Conn)

proc onRetry(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.phase != phConnecting:
    return
  c.retryTimer = nil
  io.tryConnect(c)

proc established(io: Io, c: Conn) =
  ## [SPEC TRANSPORT §8.2] The connection completed: the peer's identity is
  ## compared with the expected one before any byte is written. On a mismatch,
  ## or when it cannot be read, nothing is sent: the ticket is neither disclosed
  ## nor consumed (TRN-0190).
  let cred = peerCred(c.fd)
  if cred.isErr or cred.get.uid != c.expected.uid:
    zero(c.hello)
    let observed =
      if cred.isOk:
        Opt.some(cred.get)
      else:
        Opt.none(PeerCred)
    var f = ConnectFail(
      code: ecTransport,
      cause: cfPeerMismatch,
      msg: "the endpoint's peer is not the expected identity",
      observed: observed,
    )
    io.closeConn(c, ccProtocol, ecTransport, failure = Opt.some(f))
    return
  c.peer = Opt.some(cred.get)
  if not c.register():
    io.closeConn(
      c,
      ccPeerClosed,
      failure = fail(ecTransport, cfConnect, "the dispatcher refused the fd"),
    )
    return
  c.phase = phHello
  # [SPEC TRANSPORT §3.1, §8.1] The Hello carries the ticket; this copy is
  # zeroed now and the queued frame once written.
  discard io.commit(c, c.hello, fcControl, secret = true)
  zero(c.hello)
  c.hello = @[]
  io.updateReading(c)

proc onConnectReady(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.phase != phConnecting:
    return
  discard removeWriter2(AsyncFD(c.fd))
  c.writing = false
  let r = connectResult(c.fd)
  if r != 0:
    io.closeConn(
      c, ccPeerClosed, failure = fail(ecTransport, cfConnect, "connect: " & errText(r))
    )
    return
  io.established(c)

proc tryConnect(io: Io, c: Conn) =
  ## [SPEC TRANSPORT §3.1, §9.1; RUNTIME §4.1] Exactly `c.path`: no other path
  ## is tried and nothing is derived from the module name. A full backlog is
  ## retried until the Hello deadline; any other error is TRANSPORT_ERROR.
  let fd = unixSocket()
  if fd < 0:
    io.closeConn(
      c, ccPeerClosed, failure = fail(ecTransport, cfConnect, "socket: " & errText(fd))
    )
    return
  let r = sockConnect(fd, cstring(c.path))
  if r == 0:
    c.fd = fd
    io.established(c)
  elif -r == EINPROGRESS:
    c.fd = fd
    if not c.register() or addWriter2(AsyncFD(fd), onConnectReady, keyArg(c.key)).isErr:
      io.closeConn(
        c,
        ccPeerClosed,
        failure = fail(ecTransport, cfConnect, "the dispatcher refused the fd"),
      )
      return
    c.writing = true
  elif wouldBlock(r):
    discard fdClose(fd)
    c.retryTimer =
      setTimer(Moment.fromNow(nanoseconds(ConnectRetry)), onRetry, keyArg(c.key))
  else:
    discard fdClose(fd)
    io.closeConn(
      c, ccPeerClosed, failure = fail(ecTransport, cfConnect, "connect: " & errText(r))
    )

proc connect*(io: Io, cmd: var IoCommand) =
  ## `cmdConnect`. The ticket in `cmd` is zeroed before this returns.
  defer:
    zeroMem(addr cmd.ticket[0], cmd.ticket.len)
  if cmd.conn >= AcceptedConnBase or cmd.conn in io.conns:
    io.emit(
      IoEvent(
        conn: cmd.conn,
        kind: evLocalFailure,
        localCode: ecInvalidParams,
        localMsg: "the connection id is in use or reserved",
      )
    )
    return
  if io.stopping:
    io.failNow(cmd.conn, ecTransport, cfShutdown, "the loop is stopping")
    return
  if io.outbound >= io.config.maxOutbound:
    # [SPEC TRANSPORT §8.6] Local capacity: MODULE_ERROR, nothing opened.
    io.failNow(cmd.conn, ecModule, cfCapacity, "maxOutbound connections are open")
    return
  if not fitsSunPath(cmd.path):
    # [G58] Never shortened or substituted.
    io.failNow(cmd.conn, ecTransport, cfConnect, "the path does not fit sun_path")
    return
  let b = io.selectedBoundary(cmd.selected).valueOr:
    io.failNow(cmd.conn, ecModule, cfContract, "selected contract: " & error)
    return
  let hello = helloRequest(
    cmd.module, cmd.ticket, cmd.selected.root, io.config.peerFrameLimit
  ).valueOr:
    io.failNow(cmd.conn, ecModule, cfHello, "the Hello cannot be encoded")
    return
  let c = io.newConn(cmd.conn, roCaller, -1)
  c.phase = phConnecting
  c.expected = cmd.expected
  c.path = cmd.path
  c.sent = Hello(module: cmd.module, schema: cmd.selected.root)
  c.selected = b
  c.firstId = cmd.firstId
  c.hello = hello
  c.outboundCounted = true
  inc io.outbound
  io.track(c)
  io.armHello(c)
  io.tryConnect(c)

proc callOutcome(o: Outcome): CallOutcome =
  if o.ok:
    CallOutcome(ok: true, result: encodeCbor(o.response))
  else:
    CallOutcome(ok: false, failure: o.failure)

proc callerEvents(io: Io, c: Conn, evs: seq[CallerEvent], size: int) =
  ## `size`: the frame's body length, an Event's credit.
  var tags: seq[uint64]
  for ev in evs:
    case ev.kind
    of ceResponse:
      var tag: uint64
      if c.toTag.pop(ev.id, tag):
        c.toWire.del(tag)
        tags.add(tag)
        io.emit(
          IoEvent(
            conn: c.id, kind: evResponse, tag: tag, outcome: callOutcome(ev.outcome)
          )
        )
    of ceEvent:
      c.keep(size)
      c.undelivered += size
      io.emit(
        IoEvent(
          conn: c.id,
          kind: evEvent,
          eventSub: ev.id,
          eventName: ev.event,
          eventData: encodeCbor(ev.data),
          credit: size,
        )
      )
      if c.undelivered >= io.config.callerUndeliveredBytes:
        io.hold(c, hCredit)
    of ceSubscription:
      io.emit(
        IoEvent(
          conn: c.id,
          kind: evSubscription,
          subscriptionId: ev.id,
          subscriptionOp: ev.op,
          subscriptionFailure: ev.failure,
        )
      )
    of ceClose:
      # The responses before it in this batch are the synthetic TRANSPORT_ERRORs
      # of the closing (§3.2).
      let cause = if ev.close.send.isSome: ccProtocol else: ccPeerError
      io.closeConn(c, cause, ev.close.code, ev.close.send, ids = tags)
  if not c.closed:
    io.account(c)

proc callerFrame*(io: Io, c: Conn, body: sink seq[byte]) =
  case c.phase
  of phHello:
    let r = acceptHelloResponse(c.sent, body, io.limits)
    if r.isErr:
      # [SPEC TRANSPORT §3.1 step 5, §2.3; RUNTIME §4.1] A ProtocolError from
      # the callee closes with no reply and its code is the outcome; any
      # other failure sends ProtocolError with its code first.
      let f = r.error
      let final =
        if f.peer or c.writeFailed:
          Opt.none(seq[byte])
        else:
          Opt.some(protocolErrorBody(f.code))
      io.closeConn(
        c,
        if f.peer: ccPeerError else: ccProtocol,
        f.code,
        final,
        failure = fail(f.code, cfHello, f.msg),
      )
      return
    if c.writeFailed:
      io.closeConn(c, ccNotWritable, ecTransport)
      return
    c.helloDone()
    c.caller = callerConn(c.selected, c.firstId, io.limits)
    c.phase = phOpen
    c.connected = true
    io.emit(IoEvent(conn: c.id, kind: evConnected, connectedPeer: c.peer.get))
  of phOpen:
    let size = body.len
    io.callerEvents(c, c.caller.receive(body), size)
  else:
    discard

proc localFailure(io: Io, id: ConnId, tag: uint64, code: ErrorCode, msg: string) =
  io.emit(
    IoEvent(
      conn: id, kind: evLocalFailure, localTag: tag, localCode: code, localMsg: msg
    )
  )

proc call*(io: Io, c: Conn, cmd: IoCommand) =
  ## [SPEC TRANSPORT §4.1, §7, §8.6] `cmdCall`: a Request, or a local failure
  ## with nothing sent and no id consumed (I54's codes).
  if c.isNil or c.role != roCaller or not c.established:
    io.localFailure(cmd.conn, cmd.tag, ecNotReady, "the connection is not established")
    return
  if cmd.tag in c.toWire:
    io.localFailure(cmd.conn, cmd.tag, ecInvalidParams, "the call tag is in use")
    return
  if io.totalCalls >= io.config.maxTotalCalls:
    # [SPEC TRANSPORT §8.6] Local capacity (I54).
    io.localFailure(cmd.conn, cmd.tag, ecModule, "maxTotalCalls calls are outstanding")
    return
  let params = decodeValue(cmd.params, io.config.maxPayloadDepth).valueOr:
    io.localFailure(cmd.conn, cmd.tag, ecInvalidParams, $error)
    return
  if not io.fitsNow(c, io.requestOverhead + cmd.methodName.len + cmd.params.len):
    io.localFailure(cmd.conn, cmd.tag, ecModule, "the connection's output is full")
    return
  let (id, bytes) = c.caller.request(cmd.methodName, params).valueOr:
    io.localFailure(cmd.conn, cmd.tag, error.code, error.msg)
    if c.caller.state == csClosed:
      io.closeConn(c, ccOwner, ecTransport)
    return
  c.toWire[cmd.tag] = id
  c.toTag[id] = cmd.tag
  io.account(c)
  if not io.commit(c, bytes, fcData):
    io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))

proc cancel*(io: Io, c: Conn, tag: uint64) =
  ## [SPEC TRANSPORT §6] A Cancel for a call still awaited; otherwise nothing.
  if c.isNil or c.role != roCaller or not c.established:
    return
  let id = c.toWire.getOrDefault(tag, high(uint64))
  if id == high(uint64) and tag notin c.toWire:
    return
  let bytes = c.caller.cancel(id)
  if bytes.isSome:
    io.commitControl(c, bytes.get)

proc abandon*(io: Io, c: Conn, tag: uint64) =
  ## [SPEC TRANSPORT §3.4] Stops awaiting a call: its late Response is still
  ## validated, then discarded.
  if c.isNil or c.role != roCaller or not c.established:
    return
  var id: uint64
  if c.toWire.pop(tag, id):
    c.toTag.del(id)
    discard c.caller.abandon(id)
    io.account(c)

proc subscribe*(io: Io, c: Conn, cmd: IoCommand) =
  ## [SPEC TRANSPORT §5.1, §8.6] `cmdSubscribe`: a Subscribe, or a local
  ## failure with nothing sent (I54's codes).
  if c.isNil or c.role != roCaller or not c.established:
    io.localFailure(
      cmd.conn, cmd.subId, ecNotReady, "the connection is not established"
    )
    return
  if io.totalSubIds >= io.config.maxTotalSubscriptionIds:
    io.localFailure(
      cmd.conn, cmd.subId, ecModule, "the loop's subscription-id history is full"
    )
    return
  let bytes = c.caller.subscribe(cmd.subId, cmd.subEvent).valueOr:
    io.localFailure(cmd.conn, cmd.subId, error.code, error.msg)
    return
  io.account(c)
  io.commitControl(c, bytes)

proc unsubscribe*(io: Io, c: Conn, cmd: IoCommand) =
  if c.isNil or c.role != roCaller or not c.established:
    io.localFailure(
      cmd.conn, cmd.subId, ecNotReady, "the connection is not established"
    )
    return
  let bytes = c.caller.unsubscribe(cmd.subId).valueOr:
    io.localFailure(cmd.conn, cmd.subId, error.code, error.msg)
    return
  io.commitControl(c, bytes)

proc abandonSubscription*(io: Io, c: Conn, id: uint64) =
  ## [SPEC TRANSPORT §3.4] Its later Events are validated and not delivered.
  if c.isNil or c.role != roCaller or not c.established:
    return
  discard c.caller.abandonSubscription(id)

proc release*(io: Io, c: Conn, n: int) =
  ## Credits: the owner is done with `n` bytes of `evEvent`s; reading resumes
  ## below `callerUndeliveredBytes`.
  if c.isNil or c.role != roCaller or n <= 0:
    return
  let r = min(n, c.undelivered)
  c.undelivered -= r
  io.unkeep(c, r)
  if hCredit in c.holds and c.undelivered < io.config.callerUndeliveredBytes:
    io.unhold(c, hCredit)
