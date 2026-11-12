## TRANSPORT §3.1, §4, §6, §8.1, §8.2, §8.6: the callee side on the I/O thread.
## Accepting on an adopted listener, the connection caps, pending Hellos and
## the admission round trip (`evHello`, the owner's `acceptHello`, `cmdAdmit`),
## then the established `CalleeConn`: dispatch to the owner, `logos.schema`
## answered here, and the owner's Responses.

{.push raises: [], gcsafe.}

import chronos/asyncloop
import results
import ../../cbor
import ../../iface/[outcome, surface]
import ../[boundary, envelope, session]
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
    c.callee = calleeConn(b.get, io.limits)
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

proc introspect(io: Io, c: Conn, id: uint64) =
  ## [SPEC TRANSPORT §8.1] `logos.schema`, answered by the provider-side
  ## boundary with the selected contract's construction input only; the owner
  ## never sees it.
  let v = schemaResponse(c.callee.boundary.contracts, c.callee.boundary.selected)
  if v.isErr:
    io.respondOutcome(
      c, id, Outcome(ok: false, failure: InvocationFailure(code: ecModule))
    )
    return
  let n = encodeCbor(v.get).len
  io.respondOutcome(c, id, Outcome(ok: true, response: v.get), n)

proc act(io: Io, c: Conn, acts: seq[CalleeAction]) =
  for a in acts:
    if c.closed:
      return
    case a.kind
    of caDispatch:
      if a.introspection:
        io.introspect(c, a.request.id)
      else:
        c.dispatched.incl(a.request.id)
        io.emit(
          IoEvent(
            conn: c.id,
            kind: evDispatch,
            requestId: a.request.id,
            methodName: a.request.methodName,
            params: encodeCbor(a.request.params),
          )
        )
    of caSend:
      io.commitControl(c, a.bytes)
    of caStop:
      c.dispatched.excl(a.id)
      io.emit(IoEvent(conn: c.id, kind: evStop, stopId: a.id))
    of caSubscribe:
      # Event delivery over sockets is step 10a-2: until then every Subscribe
      # fails with MODULE_ERROR and leaves no subscription [IMPL].
      let r = c.callee.subscriptionResult(
        a.subId, Opt.some(InvocationFailure(code: ecModule))
      )
      if r.isSome:
        io.commitControl(c, r.get)
    of caUnsubscribe:
      let r = c.callee.subscriptionResult(a.id)
      if r.isSome:
        io.commitControl(c, r.get)
    of caClose:
      let cause = if a.close.send.isSome: ccProtocol else: ccPeerError
      io.closeConn(c, cause, a.close.code, a.close.send)
  if not c.closed:
    io.refreshSession(c)

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
    io.act(c, c.callee.receive(body))
  else:
    discard

proc respond*(io: Io, c: Conn, id: uint64, outcome: CallOutcome) =
  ## [SPEC TRANSPORT §4.1] The owner's terminal outcome for request `id`. The
  ## result map is decoded under the payload depth P + 1 and then checked
  ## against P and its declaration by `CalleeConn.respond`; bytes that do not
  ## decode are the module's fault (MODULE_ERROR).
  if c.role != roCallee or not c.established:
    return
  if outcome.ok:
    let v = decodeValue(outcome.result, io.config.maxPayloadDepth)
    if v.isErr:
      io.respondOutcome(
        c, id, Outcome(ok: false, failure: InvocationFailure(code: ecModule))
      )
    else:
      io.respondOutcome(c, id, Outcome(ok: true, response: v.get), outcome.result.len)
  else:
    io.respondOutcome(c, id, Outcome(ok: false, failure: outcome.failure))
