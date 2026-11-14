## TRANSPORT §3.1, §4, §5, §6, §8.1, §8.2, §8.6: the callee side on the I/O
## thread. Accepting on an adopted listener, the connection caps, pending Hellos
## and the admission round trip (`evHello`, the owner's `acceptHello`,
## `cmdAdmit`), then the established `CalleeConn` under the route's access:
## dispatch to the owner within the execution slots (A21), `logos.schema`
## answered here, the owner's Responses, subscriptions, publication, and the
## session's end.
##
## Execution slots [SPEC TRANSPORT §6, §8.6; I52 as revised by A21]: a
## dispatched Request holds one of its connection's `maxInFlight` slots and one
## of the loop's `maxTotalExecuting` until the owner reports that its work ended
## (`cmdWorkEnded`, or `cmdRespond` with `workEnded`), even after its Response,
## its CANCELLED or the connection's close. A closed connection with slots
## still held stays as a zombie until they are released. A freed slot goes to
## the connections with queued Requests in turn (round-robin), one Request each.

{.push raises: [], gcsafe.}

import std/[algorithm, sets]
import chronos/asyncloop
import results
import ../../cbor
import ../../iface/[outcome, surface]
import ../[access, boundary, envelope, session]
import ./[api, conn, endpoint, peercred, sock]

type Outcome = outcome.Outcome ## `commitment/choice` exports another `Outcome`

proc failServe(io: Io, id: EndpointId, fd: cint, msg: string) =
  if fd >= 0:
    discard fdClose(fd)
  io.emit(IoEvent(kind: evServeFailed, failedEndpoint: id, serveError: msg))

proc onAcceptable(arg: pointer) {.gcsafe, raises: [].}

proc serve*(io: Io, cmd: IoCommand) =
  ## [SPEC TRANSPORT §8.2] Accepts on an adopted listening fd, which the I/O
  ## thread then owns; nothing here binds, unlinks or derives a path. The
  ## contract input is the provider's primary contract, from which the
  ## boundary of any contract this endpoint serves is built.
  if io.stopping:
    io.failServe(cmd.endpoint, cmd.listener, "the loop is stopping")
    return
  if cmd.endpoint in io.serves:
    io.failServe(cmd.endpoint, cmd.listener, "the endpoint id is already served")
    return
  adoptListener(cmd.listener).isOkOr:
    io.failServe(cmd.endpoint, cmd.listener, error.msg)
    return
  let set = acceptSchemaResponse(
    cmd.contract.schema, cmd.contract.root, AcceptOptions(system: cmd.contract.system)
  ).valueOr:
    io.failServe(cmd.endpoint, cmd.listener, "contract input: " & error)
    return
  let s = Serve(
    key: io.newKey(),
    id: cmd.endpoint,
    fd: cmd.listener,
    served: cmd.served,
    contracts: set,
  )
  if register2(AsyncFD(s.fd)).isErr:
    io.failServe(cmd.endpoint, cmd.listener, "the dispatcher refused the listener")
    return
  if addReader2(AsyncFD(s.fd), onAcceptable, keyArg(s.key)).isErr:
    discard unregister2(AsyncFD(s.fd))
    io.failServe(cmd.endpoint, cmd.listener, "the dispatcher refused the listener")
    return
  io.serves[s.id] = s
  io.serveByKey[s.key] = s
  io.emit(IoEvent(kind: evListening, listening: s.id))

proc stopServing*(io: Io, id: EndpointId, closePending = true) =
  ## Stops accepting and closes the I/O thread's listener fd; it never unlinks
  ## (`removeEndpoint` is the owner's). Established connections stay. Hellos
  ## pending at the endpoint close, since they can no longer be admitted
  ## [IMPL].
  var s: Serve
  if not io.serves.pop(id, s):
    return
  io.serveByKey.del(s.key)
  discard removeReader2(AsyncFD(s.fd))
  discard unregister2(AsyncFD(s.fd))
  discard fdClose(s.fd)
  if closePending:
    var pend: seq[Conn]
    for c in io.conns.values:
      if c.role == roCallee and c.endpoint == id and not c.established:
        pend.add(c)
    for c in pend:
      io.closeConn(c, ccOwner, ecTransport)

proc refuse(fd: cint) =
  ## [SPEC TRANSPORT §2.3, §8.6] At a connection cap: ProtocolError
  ## MODULE_ERROR, written before anything is read (permitted before the
  ## Hello), then close [IMPL; TRN-0276's code for capacity]. The socket is
  ## new, so the frame fits its send buffer.
  let f = framed(protocolErrorBody(ecModule))
  discard sockSend(fd, unsafeAddr f[0], csize_t(f.len))
  discard fdClose(fd)

proc onAcceptable(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let s = io.serveByKey.getOrDefault(argKey(arg))
  if s.isNil:
    return
  while true:
    let fd = sockAccept(s.fd)
    if fd < 0:
      # EAGAIN, or an error such as a connection aborted before accept: the
      # listener stays readable while more are queued.
      return
    if io.stopping or io.inbound >= io.config.maxInbound or
        io.pendingHellos >= io.config.maxPendingHellos:
      refuse(fd)
      continue
    let c = io.newConn(io.nextAccepted, roCallee, fd)
    inc io.nextAccepted
    c.endpoint = s.id
    c.phase = phHello
    # Diagnostics only: the callee's decision is the Hello (§8.1, §8.2).
    let cred = peerCred(fd)
    if cred.isOk:
      c.peer = Opt.some(cred.get)
    if not c.register():
      discard fdClose(fd)
      continue
    c.inbound = true
    inc io.inbound
    c.pendingHello = true
    inc io.pendingHellos
    io.track(c)
    io.armHello(c)
    io.updateReading(c)

proc onEnd(arg: pointer) {.gcsafe, raises: [].}

proc boundaryFor(s: Serve, contract: Digest): Result[Boundary, string] =
  var b: Boundary
  if s.boundaries.pop(contract, b):
    s.boundaries[contract] = b
    return ok(b)
  b = ?boundary(s.contracts, contract)
  s.boundaries[contract] = b
  ok(b)

proc admit*(io: Io, c: Conn, v: AdmitVerdict) =
  ## [SPEC TRANSPORT §3.1, §8.1] The owner's verdict on the Hello. A verdict for
  ## a connection that closed meanwhile (the Hello deadline) is discarded; a
  ## ticket redeemed by then stays consumed.
  if c.phase != phAdmitting:
    return
  case v.kind
  of avEstablished:
    let s = io.serves.getOrDefault(c.endpoint)
    let b =
      if s.isNil:
        Result[Boundary, string].err("the endpoint is no longer served")
      else:
        s.boundaryFor(v.binding.contract)
    if b.isErr:
      io.closeConn(c, ccProtocol, ecModule, Opt.some(protocolErrorBody(ecModule)))
      return
    # [SPEC TRANSPORT §8.1; RUNTIME §9.3] The route's method, subscription and
    # publication access, for the life of the session.
    let scope = b.get.applyAccess(v.binding.access)
    c.callee = calleeConn(scope.boundary, io.limits, scope.publishScope, io.slots)
    c.phase = phOpen
    if not io.commit(c, v.response, fcControl):
      io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))
      return
    c.helloDone()
    c.pendingHello = false
    dec io.pendingHellos
    io.emit(
      IoEvent(
        conn: c.id,
        kind: evEstablished,
        endpoint: c.endpoint,
        binding: v.binding,
        peer: c.peer,
      )
    )
    if scope.unknown.len > 0:
      # Cannot come from a route the Runtime validated (RUNTIME l.3019-3020):
      # the scope narrowed, failing closed.
      io.emit(
        IoEvent(
          conn: c.id,
          kind: evLocalFailure,
          localCode: ecNotAuthorised,
          localMsg:
            $scope.unknown.len &
            " route access items name nothing in the selected contract",
        )
      )
    if v.endsIn.isSome:
      # [SPEC TRANSPORT §8.1] The session ends with its decision (TRN-0317).
      c.endTimer = setTimer(fromNow(max(0'i64, v.endsIn.get)), onEnd, keyArg(c.key))
    io.unhold(c, hAdmit)
  of avFailed:
    # [SPEC TRANSPORT §2.3, §3.1] A ProtocolError from the caller closes with
    # no reply; any other failure sends its code.
    if v.peer:
      io.closeConn(c, ccPeerError, v.code)
    else:
      io.closeConn(c, ccProtocol, v.code, Opt.some(protocolErrorBody(v.code)))
  of avUnavailable:
    # [SPEC TRANSPORT §3.1 step 3] The ticket was not evaluated: it stays live.
    io.closeConn(c, ccProtocol, ecModule, Opt.some(protocolErrorBody(ecModule)))

proc workEnded*(io: Io, c: Conn, id: uint64)

proc queueForSlots(io: Io, c: Conn) =
  if c.callee.delayedRequests > 0 and not c.slotQueued:
    c.slotQueued = true
    io.slotWaiters.addLast(c.key)

proc act(io: Io, c: Conn, acts: seq[CalleeAction]) =
  for a in acts:
    if c.closed:
      return
    case a.kind
    of caDispatch:
      # [E3; DECISIONS I90] `logos.schema` too goes to the owner, which
      # authorizes it as any call and answers with `cmdIntrospect`.
      c.dispatched.incl(a.request.id)
      io.emit(
        IoEvent(
          conn: c.id,
          kind: evDispatch,
          requestId: a.request.id,
          methodName: a.request.methodName,
          params: encodeCbor(a.request.params),
          introspection: a.introspection,
        )
      )
    of caSend:
      io.commitControl(c, a.bytes)
    of caStop:
      c.dispatched.excl(a.id)
      io.emit(IoEvent(conn: c.id, kind: evStop, stopId: a.id))
    of caSubscribe:
      io.account(c)
      if io.totalSubs > io.config.maxTotalSubscriptions:
        # [SPEC TRANSPORT §8.6] The loop's subscriptions are exhausted: a
        # failed result, the session stays [IMPL].
        let r = c.callee.subscriptionResult(
          a.subId, Opt.some(InvocationFailure(code: ecModule))
        )
        if r.isSome:
          io.commitControl(c, r.get)
      else:
        io.emit(
          IoEvent(
            conn: c.id, kind: evSubscribe, subscribeId: a.subId, subscribeEvent: a.event
          )
        )
    of caUnsubscribe:
      io.emit(IoEvent(conn: c.id, kind: evUnsubscribe, subscribeId: a.id))
    of caClose:
      let cause = if a.close.send.isSome: ccProtocol else: ccPeerError
      io.closeConn(c, cause, a.close.code, a.close.send)
  if not c.closed:
    io.syncDelayed(c)
    io.account(c)
    io.queueForSlots(c)

proc admitWaiting(io: Io) =
  ## [SPEC TRANSPORT §8.6] Free slots of the loop's pool go to the connections
  ## with queued Requests in turn, one Request each, until the pool is full or
  ## every waiting connection is at its own `maxInFlight`. Not reentrant: a
  ## slot freed while dispatching (an introspection) is handled by the loop.
  if io.admitting:
    io.admitAgain = true
    return
  io.admitting = true
  defer:
    io.admitting = false
  while true:
    io.admitAgain = false
    var idle = 0
    while io.slotWaiters.len > 0 and io.slots.used < io.slots.cap and
        idle < io.slotWaiters.len:
      let key = io.slotWaiters.popFirst
      let c = io.lookup(key)
      if c.isNil:
        continue
      c.slotQueued = false
      if c.closed or c.role != roCallee or not c.established or
          c.callee.delayedRequests == 0:
        continue
      let acts = c.callee.admitDelayed(1)
      if acts.len == 0:
        # At its own `maxInFlight`, or terminating: it waits for its own slot.
        c.slotQueued = true
        io.slotWaiters.addLast(key)
        inc idle
        continue
      idle = 0
      io.act(c, acts)
    if not io.admitAgain:
      return

proc workEnded*(io: Io, c: Conn, id: uint64) =
  ## [SPEC TRANSPORT §6, §8.6] Releases the execution slot of request `id`, on
  ## an open connection or a zombie, then hands free slots to queued Requests.
  if c.role != roCallee or not c.callee.isExecuting(id):
    return
  io.act(c, c.callee.workEnded(id))
  if c.closed and c.callee.executing == 0:
    io.zombies.del(c.id)
  io.admitWaiting()

proc introspect*(io: Io, c: Conn, id: uint64) =
  ## [SPEC TRANSPORT §8.1; E3] `cmdIntrospect`: the owner authorized the
  ## dispatched `logos.schema` Request `id`; the provider-side boundary answers
  ## with the selected contract's construction input only, and its slot is
  ## released. On a closed connection only the slot is released.
  if c.role != roCallee or not c.callee.isExecuting(id):
    return
  if c.established and c.callee.isInFlight(id):
    let v = schemaResponse(c.callee.boundary.contracts, c.callee.boundary.selected)
    if v.isErr:
      io.respondOutcome(
        c, id, Outcome(ok: false, failure: InvocationFailure(code: ecModule))
      )
    else:
      let n = encodeCbor(v.get).len
      io.respondOutcome(c, id, Outcome(ok: true, response: v.get), n)
  io.workEnded(c, id)

proc calleeFrame*(io: Io, c: Conn, body: sink seq[byte]) =
  case c.phase
  of phHello:
    # [SPEC TRANSPORT §3.1, §2.3] The first frame goes to the owner, which
    # runs `acceptHello`; nothing more is read until its verdict (S10a-1).
    c.phase = phAdmitting
    io.hold(c, hAdmit)
    io.emit(
      IoEvent(
        conn: c.id,
        kind: evHello,
        helloEndpoint: c.endpoint,
        frame: body,
        helloPeer: c.peer,
      )
    )
  of phOpen:
    let acts = c.callee.receive(body)
    io.account(c)
    if io.totalSubIds > io.config.maxTotalSubscriptionIds:
      # [SPEC TRANSPORT §8.6] The loop's subscription-id history is full.
      io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))
      return
    io.act(c, acts)
  else:
    discard

proc respond*(
    io: Io, c: Conn, id: uint64, outcome: CallOutcome, workEnded: bool, charge: int
) =
  ## [SPEC TRANSPORT §4.1] The owner's terminal outcome for request `id`. The
  ## result map is decoded under the payload depth P + 1 and then checked
  ## against P and its declaration by `CalleeConn.respond`; bytes that do not
  ## decode are the module's fault (MODULE_ERROR). `charge` leaves
  ## `maxPendingOutputBytes` once the Response is committed or discarded.
  if c.role != roCallee:
    io.uncharge(charge)
    return
  if not c.established:
    io.uncharge(charge)
  elif outcome.ok:
    let v = decodeValue(outcome.result, io.config.maxPayloadDepth)
    if v.isErr:
      io.uncharge(charge)
      io.respondOutcome(
        c, id, Outcome(ok: false, failure: InvocationFailure(code: ecModule))
      )
    else:
      io.respondOutcome(
        c, id, Outcome(ok: true, response: v.get), outcome.result.len, charge
      )
  else:
    io.uncharge(charge)
    io.respondOutcome(c, id, Outcome(ok: false, failure: outcome.failure))
  if workEnded:
    io.workEnded(c, id)

proc subscriptionResult*(io: Io, c: Conn, id: uint64, failure: Opt[InvocationFailure]) =
  ## [SPEC TRANSPORT §5.1] The owner's answer to `evSubscribe` or
  ## `evUnsubscribe`: completes the outstanding operation of `id`.
  if c.role != roCallee or not c.established:
    return
  let r = c.callee.subscriptionResult(id, failure)
  if r.isSome:
    io.commitControl(c, r.get)
  if not c.closed:
    io.account(c)

# Publication -----------------------------------------------------------------------

proc publishFailed(
    io: Io, c: Conn, e: PublishError, event: string, request: Opt[uint64]
) =
  io.emit(
    IoEvent(
      conn: c.id,
      kind: evPublishFailed,
      pubFailKind: e.kind,
      pubFailCode: e.code,
      pubFailEvent: event,
      pubFailRequest: request,
      pubFailMsg: e.msg,
    )
  )

proc overflow(io: Io, c: Conn) =
  ## [SPEC TRANSPORT §5.2] Event output overflow: ProtocolError TRANSPORT_ERROR
  ## from the final slot, a flush bounded by `closeLinger`, then close. Closure
  ## ends every subscription on the connection; no committed Event is dropped
  ## silently (the connection closes instead).
  io.closeConn(c, ccOverflow, ecTransport, Opt.some(protocolErrorBody(ecTransport)))

proc refused(
    io: Io,
    c: Conn,
    e: PublishError,
    event: string,
    request: Opt[uint64],
    tooLarge: TooLargeAction,
) =
  if e.kind == peTooLarge and tooLarge == tlClose:
    # [SPEC TRANSPORT §2.1; G165(a)]
    io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))
  else:
    io.publishFailed(c, e, event, request)

proc commitEvents(io: Io, c: Conn, frames: seq[seq[byte]]) =
  ## [SPEC TRANSPORT §2.1, §5.2] Each Event is committed when appended to the
  ## connection's ordered output; one that finds no room overflows.
  for f in frames:
    if c.closed:
      return
    if not io.commit(c, f, fcEvent):
      io.overflow(c)
      return

proc decodeData(io: Io, data: openArray[byte]): Result[CborValue, PublishError] =
  ## The owner's encoded data, under the payload depth P + 1; its schema and P
  ## are checked by the session.
  let v = decodeValue(data, io.config.maxPayloadDepth)
  if v.isErr:
    return err(PublishError(kind: peInvalid, msg: "the data does not decode"))
  ok(v.get)

proc publishTo(io: Io, c: Conn, data: var Opt[CborValue], cmd: IoCommand) =
  ## One connection's part of an ordinary publication.
  let ids = c.callee.subscribersOf(cmd.event)
  if ids.len == 0:
    return
  if data.isNone:
    let d = io.decodeData(cmd.data)
    if d.isErr:
      io.publishFailed(c, d.error, cmd.event, Opt.none(uint64))
      return
    data = Opt.some(d.get)
  for id in ids:
    let r = c.callee.publish(id, data.get)
    if r.isErr:
      io.refused(c, r.error, cmd.event, Opt.none(uint64), cmd.tooLarge)
      break
    io.commitEvents(c, @[r.get])
    if c.closed:
      break

proc publish*(io: Io, cmd: IoCommand) =
  ## [SPEC TRANSPORT §5.1, §5.2, §8.1] `cmdPublish`: an Event to every active
  ## subscription to `event` on the established connections of the endpoint,
  ## within each connection's publish scope, by connection then subscription
  ## id. Each refusal is reported per connection; a successful commit is not.
  var conns: seq[Conn]
  for c in io.conns.values:
    if c.role == roCallee and c.established and c.endpoint == cmd.pubEndpoint:
      conns.add(c)
  conns.sort(
    proc(a, b: Conn): int =
      cmp(a.id, b.id)
  )
  var data = Opt.none(CborValue)
  for c in conns:
    io.publishTo(c, data, cmd)

proc publishConn*(io: Io, c: Conn, cmd: IoCommand) =
  ## [SPEC TRANSPORT §5.1, §5.2; E1, DECISIONS I90] `cmdPublishConn`: an
  ## ordinary Event to the active subscriptions to `event` on one connection,
  ## within its publish scope, by subscription id; a refusal is reported as for
  ## `cmdPublish`. Nothing is reported for a connection already closed.
  if c.isNil or c.role != roCallee or not c.established:
    return
  var data = Opt.none(CborValue)
  io.publishTo(c, data, cmd)

proc publishResult(io: Io, conn: ConnId, cmd: IoCommand, failure: Opt[PublishFailure]) =
  io.emit(
    IoEvent(
      conn: conn,
      kind: evPublishResult,
      pubResultTag: cmd.pubTag,
      pubResultRequest: cmd.pubRequest,
      pubResultFailure: failure,
    )
  )

func toFailure(e: PublishError): Opt[PublishFailure] =
  Opt.some(PublishFailure(kind: e.kind, code: e.code, msg: e.msg))

proc publishScoped*(io: Io, c: Conn, cmd: IoCommand) =
  ## [SPEC TRANSPORT §5.2, §6; RUNTIME §7.3.1] `cmdPublishScoped`: one Event
  ## per active subscription to `event` on the invocation's connection, while
  ## the request is in flight. [E2; DECISIONS I90] Every one is answered by an
  ## `evPublishResult`, committed or not, so its publisher learns the outcome
  ## (INTERFACE l.2189-2196). A too-large Event under `tlClose` closes the
  ## connection after its failure is reported.
  if c.isNil or c.role != roCallee or not c.established:
    io.publishResult(
      cmd.conn,
      cmd,
      Opt.some(
        PublishFailure(
          kind: peClosed, code: ecTransport, msg: "the connection is closed"
        )
      ),
    )
    return
  let data = io.decodeData(cmd.data).valueOr:
    io.publishResult(c.id, cmd, toFailure(error))
    return
  let frames = c.callee.publishScoped(cmd.pubRequest, cmd.event, data).valueOr:
    io.publishResult(c.id, cmd, toFailure(error))
    if error.kind == peTooLarge and cmd.tooLarge == tlClose:
      # [SPEC TRANSPORT §2.1; G165(a)]
      io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))
    return
  io.commitEvents(c, frames)
  if c.closed:
    # The output overflowed while committing: closure ends the invocation's
    # subscriptions, and the Event was not delivered (§5.2).
    io.publishResult(
      c.id,
      cmd,
      Opt.some(
        PublishFailure(kind: peClosed, code: ecTransport, msg: "the connection closed")
      ),
    )
  else:
    io.publishResult(c.id, cmd, Opt.none(PublishFailure))

# The session's end -----------------------------------------------------------------

proc finishTermination(io: Io, c: Conn) =
  ## [SPEC TRANSPORT §8.1] ProtocolError NOT_AUTHORISED from the final slot, a
  ## flush bounded by `closeLinger`, then close (TRN-0323, TRN-0325).
  if c.closed:
    return
  for a in c.callee.finishTermination():
    if a.kind == caClose:
      io.closeConn(c, ccTerminated, ecNotAuthorised, a.close.send)

proc onDrain(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.closed:
    return
  c.drainTimer = nil
  io.finishTermination(c)

proc terminate*(io: Io, c: Conn) =
  ## [SPEC TRANSPORT §8.1] The route expired or was revoked: admission stops,
  ## queued Requests get NOT_AUTHORISED without dispatch, subscriptions end;
  ## in-flight work gets `terminationDrain`, then the session closes. Nothing
  ## waits for another Request or reads unread input (TRN-0322).
  if c.role != roCallee or not c.established or c.callee.state != csOpen:
    return
  cancelTimer(c.endTimer)
  io.act(c, c.callee.beginTermination())
  if c.closed:
    return
  if io.config.terminationDrain <= 0:
    io.finishTermination(c)
  else:
    c.drainTimer = setTimer(fromNow(io.config.terminationDrain), onDrain, keyArg(c.key))

proc onEnd(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.closed:
    return
  c.endTimer = nil
  io.terminate(c)
