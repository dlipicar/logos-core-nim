## TRANSPORT §1.4, §3.2, §3.3, §4, §6, §7 and the receiver rules G30–G32, G36,
## G37: one established connection, for each side, as a pure state machine.
## Each received frame body yields actions (dispatch, send these bytes, stop,
## close); each local operation yields the bytes to send. No I/O, no clocks.

{.push raises: [].}

import std/[sets, tables]
import results
import ../cbor
import ./[boundary, envelope, framing]

export results, boundary, envelope, framing

type
  ConnState* = enum
    csOpen
    csClosed

  CloseReason* = object
    ## Why a connection closed. `send` is the ProtocolError to send first when
    ## the connection is still writable; none when the peer closed or reported.
    send*: Opt[seq[byte]]
    code*: ErrorCode
    msg*: string

func protocolError(code: ErrorCode): seq[byte] =
  ## [SPEC TRANSPORT §1.3] A ProtocolError without message or detail.
  encodeCbor(
    toCbor(Message(kind: mkProtocolError, protocolError: InvocationFailure(code: code)))
  )

func closing(code: ErrorCode, msg: string): CloseReason =
  CloseReason(send: Opt.some(protocolError(code)), code: code, msg: msg)

func peerClosed(code: ErrorCode, msg: string): CloseReason =
  CloseReason(code: code, msg: msg)

func failureOf(code: ErrorCode, msg = ""): InvocationFailure =
  var f = InvocationFailure(code: code)
  if msg.len > 0 and msg.len <= MaxMessageBytes:
    f.message = Opt.some(msg)
  f

# Callee ----------------------------------------------------------------------------

type
  CalleeActionKind* = enum
    caDispatch ## run `request` (envelope and boundary checks passed)
    caSend ## send `bytes`: a committed Response or SubscriptionResult
    caStop ## try to stop request `id`: its CANCELLED Response is committed (§6)
    caSubscribe ## decide Subscribe `id` for `event`, then `subscriptionResult`
    caUnsubscribe ## decide Unsubscribe `id`, then `subscriptionResult`
    caClose ## close, after sending `close.send` when writable

  CalleeAction* = object
    case kind*: CalleeActionKind
    of caDispatch:
      request*: Request
      introspection*: bool ## `logos.schema`: answered by the provider-side boundary
    of caSend:
      bytes*: seq[byte]
    of caStop, caUnsubscribe:
      id*: uint64
    of caSubscribe:
      subId*: uint64
      event*: string
    of caClose:
      close*: CloseReason

  CalleeSub = object
    event: string
    active: bool ## its subscription-result-ok is committed
    pending: Opt[MessageKind] ## an outstanding control operation

  CalleeConn* = object ## The callee side of one established provider session.
    boundary*: Boundary
    state*: ConnState
    highestId: Opt[uint64] ## the highest Request id received (§7)
    inFlight: Table[uint64, string] ## Request id -> method, until committed
    subs: Table[uint64, CalleeSub]

func calleeConn*(b: Boundary): CalleeConn =
  CalleeConn(boundary: b, state: csOpen)

func inFlight*(c: CalleeConn): int =
  c.inFlight.len

func send(bytes: seq[byte]): CalleeAction =
  CalleeAction(kind: caSend, bytes: bytes)

proc close(c: var CalleeConn, r: CloseReason): seq[CalleeAction] =
  ## [SPEC TRANSPORT §3.2] Closing ends every subscription; in-flight requests
  ## are abandoned (their callers see TRANSPORT_ERROR).
  c.state = csClosed
  c.inFlight.clear()
  c.subs.clear()
  @[CalleeAction(kind: caClose, close: r)]

func subResult(id: uint64, op: MessageKind, f: Opt[InvocationFailure]): seq[byte] =
  encodeCbor(
    toCbor(
      Message(
        kind: mkSubscriptionResult,
        subscriptionResult: SubscriptionResult(id: id, operation: op, failure: f),
      )
    )
  )

proc onRequest(c: var CalleeConn, r: Request): seq[CalleeAction] =
  # [SPEC TRANSPORT §7] Request ids strictly increase on a connection.
  if c.highestId.isSome and r.id <= c.highestId.get:
    return c.close(closing(ecInvalidParams, "a Request id did not increase"))
  c.highestId = Opt.some(r.id)
  let checked = c.boundary.acceptRequest(r)
  if checked.isErr:
    let rj = checked.error
    case rj.kind
    of rjClose:
      return c.close(closing(ecInvalidParams, rj.msg))
    of rjRespond:
      # Committed now: the call fails as it would in direct mode; nothing runs.
      let resp = Message(
        kind: mkResponse, response: Response(id: r.id, ok: false, failure: rj.failure)
      )
      return @[send(encodeCbor(toCbor(resp)))]
  c.inFlight[r.id] = r.methodName
  @[
    CalleeAction(
      kind: caDispatch,
      request: r,
      introspection: c.boundary.isIntrospection(r.methodName),
    )
  ]

proc onCancel(c: var CalleeConn, id: uint64): seq[CalleeAction] =
  ## [SPEC TRANSPORT §6] Before the terminal Response: commit exactly one
  ## CANCELLED Response and try to stop the operation. Otherwise ignore it, with
  ## no reply and no state change.
  if id notin c.inFlight:
    return @[]
  c.inFlight.del(id)
  let resp = Message(
    kind: mkResponse,
    response: Response(id: id, ok: false, failure: failureOf(ecCancelled)),
  )
  @[send(encodeCbor(toCbor(resp))), CalleeAction(kind: caStop, id: id)]

proc onSubscribe(c: var CalleeConn, s: Subscribe): seq[CalleeAction] =
  ## [SPEC TRANSPORT §5.1] One SubscriptionResult per valid Subscribe. Reusing
  ## an id, or a second operation while one is outstanding, fails with
  ## INVALID_PARAMS and changes nothing [IMPL-DECISION G32].
  if s.id in c.subs:
    return @[send(subResult(s.id, mkSubscribe, Opt.some(failureOf(ecInvalidParams))))]
  if not c.boundary.knowsEvent(s.event):
    # Resolved under the selected contract only; the route's subscription
    # scope is the Runtime's to enforce on caSubscribe (tier 4).
    return @[send(subResult(s.id, mkSubscribe, Opt.some(failureOf(ecNotAuthorised))))]
  c.subs[s.id] = CalleeSub(event: s.event, pending: Opt.some(mkSubscribe))
  @[CalleeAction(kind: caSubscribe, subId: s.id, event: s.event)]

proc onUnsubscribe(c: var CalleeConn, id: uint64): seq[CalleeAction] =
  ## [SPEC TRANSPORT §5.1] An unknown id, or one with an outstanding
  ## operation, fails with INVALID_PARAMS and changes nothing [IMPL-DECISION G32].
  var found = false
  c.subs.withValue(id, s):
    if s.active and s.pending.isNone:
      s.pending = Opt.some(mkUnsubscribe)
      found = true
  if not found:
    return @[send(subResult(id, mkUnsubscribe, Opt.some(failureOf(ecInvalidParams))))]
  @[CalleeAction(kind: caUnsubscribe, id: id)]

proc frameFailed*(c: var CalleeConn, e: FrameError): seq[CalleeAction] =
  ## [SPEC TRANSPORT §2.1, §8.3] The frame reader refused a length prefix: send
  ## INVALID_PARAMS when writable, then close.
  if c.state == csClosed:
    return @[]
  c.close(closing(ecInvalidParams, "frame of " & $e.declared & " bytes over the limit"))

proc receive*(c: var CalleeConn, frame: openArray[byte]): seq[CalleeAction] =
  ## One frame body from the caller.
  if c.state == csClosed:
    return @[]
  let m = decodeMessage(frame).valueOr:
    # [SPEC TRANSPORT §2.3, §8.3, §10]
    return c.close(closing(ecInvalidParams, $error))
  case m.kind
  of mkRequest:
    c.onRequest(m.request)
  of mkCancel:
    c.onCancel(m.cancel.id)
  of mkSubscribe:
    c.onSubscribe(m.subscribe)
  of mkUnsubscribe:
    c.onUnsubscribe(m.unsubscribe.id)
  of mkHello:
    # [SPEC TRANSPORT §3.3]
    c.close(closing(ecInvalidParams, "a Hello after establishment"))
  of mkProtocolError:
    c.close(peerClosed(m.protocolError.code, "the caller reported an error"))
  of mkResponse, mkEvent, mkSubscriptionResult:
    # [IMPL-DECISION G30] A callee-to-caller kind from the caller.
    c.close(closing(ecInvalidParams, "a message in the wrong direction"))

proc respond*(c: var CalleeConn, id: uint64, outcome: Outcome): Opt[seq[byte]] =
  ## [SPEC TRANSPORT §4.1, §6] The one terminal Response of request `id`, or
  ## none when its Response is already committed (CANCELLED) or the connection
  ## is closed. A provider response outside its schema is MODULE_ERROR, as in
  ## direct mode (INTERFACE §4.3).
  if c.state == csClosed:
    return Opt.none(seq[byte])
  var methodName: string
  if not c.inFlight.pop(id, methodName):
    return Opt.none(seq[byte])
  var resp: Response
  if outcome.ok:
    let commitment = c.boundary.commitResponse(methodName, outcome.response)
    resp =
      if commitment.isOk:
        Response(
          id: id, ok: true, resultMap: outcome.response, commitment: commitment.get
        )
      else:
        Response(id: id, ok: false, failure: failureOf(ecModule))
  elif checkFailure(outcome.failure).isOk:
    resp = Response(id: id, ok: false, failure: outcome.failure)
  else:
    # A failure the envelope cannot carry (code 0, an over-long message,
    # detail its code does not allow) is the module's fault [IMPL].
    resp = Response(id: id, ok: false, failure: failureOf(ecModule))
  Opt.some(encodeCbor(toCbor(Message(kind: mkResponse, response: resp))))

proc subscriptionResult*(
    c: var CalleeConn, id: uint64, failure = Opt.none(InvocationFailure)
): Opt[seq[byte]] =
  ## [SPEC TRANSPORT §5.1] Completes the outstanding operation of `id`. A failure
  ## leaves the subscription state unchanged.
  if c.state == csClosed:
    return Opt.none(seq[byte])
  var op = Opt.none(MessageKind)
  var drop = false
  c.subs.withValue(id, s):
    op = s.pending
    s.pending = Opt.none(MessageKind)
    if op.isSome and failure.isNone:
      if op.get == mkSubscribe:
        s.active = true
      else:
        drop = true
    elif op == Opt.some(mkSubscribe):
      drop = true # a failed Subscribe leaves no subscription
  if op.isNone:
    return Opt.none(seq[byte])
  if drop:
    c.subs.del(id)
  Opt.some(subResult(id, op.get, failure))

proc publish*(
    c: var CalleeConn, id: uint64, data: CborValue
): Result[seq[byte], string] =
  ## [SPEC TRANSPORT §4.1, §5.1] An Event for active subscription `id`, with its
  ## payload commitment. Nothing is sent before the successful result or after
  ## a successful Unsubscribe.
  if c.state == csClosed:
    return err("the connection is closed")
  var event = ""
  var active = false
  c.subs.withValue(id, s):
    active = s.active
    event = s.event
  if not active:
    return err("no active subscription " & $id)
  let commitment = ?c.boundary.commitEvent(event, data)
  ok(
    encodeCbor(
      toCbor(
        Message(
          kind: mkEvent,
          event: Event(sub: id, event: event, data: data, commitment: commitment),
        )
      )
    )
  )

# Caller ----------------------------------------------------------------------------

type
  CallerEventKind* = enum
    ceResponse ## request `id` finished with `outcome`
    ceEvent ## an Event for subscription `id`
    ceSubscription ## the operation `op` on subscription `id` completed
    ceClose ## the connection closed; pending calls are reported as ceResponse

  CallerEvent* = object
    id*: uint64
    case kind*: CallerEventKind
    of ceResponse:
      outcome*: Outcome
    of ceEvent:
      event*: string
      data*: CborValue
    of ceSubscription:
      op*: MessageKind
      failure*: Opt[InvocationFailure]
    of ceClose:
      close*: CloseReason

  CallerSub = object
    event: string
    active: bool
    pending: Opt[MessageKind]

  CallerConn* = object ## The caller side of one established provider session.
    boundary*: Boundary
    state*: ConnState
    lastId: Opt[uint64] ## the last Request id transmitted
    pending: Table[uint64, string] ## Request id -> method
    abandoned: HashSet[uint64] ## ids whose late Response is dropped (G31)
    subs: Table[uint64, CallerSub]

func callerConn*(b: Boundary, firstId = 0'u64): CallerConn =
  ## `firstId` is the first Request id; later ones are each one larger.
  var c = CallerConn(boundary: b, state: csOpen)
  if firstId > 0:
    c.lastId = Opt.some(firstId - 1)
  c

func pendingCalls*(c: CallerConn): int =
  c.pending.len

proc shut(c: var CallerConn, r: CloseReason): seq[CallerEvent] =
  ## [SPEC TRANSPORT §3.2] Every pending call fails with a synthetic
  ## TRANSPORT_ERROR and every subscription ends. Requests are not replayed.
  var events: seq[CallerEvent]
  for id, _ in c.pending:
    events.add(
      CallerEvent(
        id: id,
        kind: ceResponse,
        outcome: Outcome(ok: false, failure: failureOf(ecTransport)),
      )
    )
  c.state = csClosed
  c.pending.clear()
  c.abandoned.clear()
  c.subs.clear()
  events.add(CallerEvent(kind: ceClose, close: r))
  events

proc close*(c: var CallerConn): seq[CallerEvent] =
  ## Closes the connection locally (or after the carrier dropped).
  if c.state == csClosed:
    return @[]
  c.shut(peerClosed(ecTransport, "closed"))

proc request*(
    c: var CallerConn, methodName: string, params: CborValue
): Result[(uint64, seq[byte]), string] =
  ## [SPEC TRANSPORT §4.1, §7] A Request with the next id and the commitment of
  ## its validated params. With no larger id left, the connection closes and
  ## nothing is sent.
  if c.state == csClosed:
    return err("the connection is closed")
  let commitment = ?c.boundary.commitRequest(methodName, params)
  if c.lastId == Opt.some(high(uint64)):
    discard c.shut(peerClosed(ecTransport, "no larger Request id"))
    return err("no larger Request id: the connection is closed")
  let id =
    if c.lastId.isSome:
      c.lastId.get + 1
    else:
      0'u64
  let bytes = encodeCbor(
    toCbor(
      Message(
        kind: mkRequest,
        request: Request(
          id: id, methodName: methodName, params: params, commitment: commitment
        ),
      )
    )
  )
  c.lastId = Opt.some(id)
  c.pending[id] = methodName
  ok((id, bytes))

func cancel*(c: CallerConn, id: uint64): Opt[seq[byte]] =
  ## [SPEC TRANSPORT §6] A Cancel for a pending request. It still gets exactly
  ## one Response: CANCELLED or the one already committed.
  if c.state == csClosed or id notin c.pending:
    return Opt.none(seq[byte])
  Opt.some(encodeCbor(toCbor(Message(kind: mkCancel, cancel: Cancel(id: id)))))

proc abandon*(c: var CallerConn, id: uint64): bool =
  ## Gives up on a pending request (a local timeout); its late Response is
  ## dropped without closing [IMPL-DECISION G31].
  if id notin c.pending:
    return false
  c.pending.del(id)
  c.abandoned.incl(id)
  true

proc subscribe*(
    c: var CallerConn, id: uint64, event: string
): Result[seq[byte], string] =
  ## [SPEC TRANSPORT §5.1] A Subscribe with a fresh id for an event of the
  ## selected contract.
  if c.state == csClosed:
    return err("the connection is closed")
  if id in c.subs:
    return err("subscription id " & $id & " is in use")
  if not c.boundary.knowsEvent(event):
    return err(event & " is not an event of the selected contract")
  c.subs[id] = CallerSub(event: event, pending: Opt.some(mkSubscribe))
  ok(
    encodeCbor(
      toCbor(Message(kind: mkSubscribe, subscribe: Subscribe(id: id, event: event)))
    )
  )

proc unsubscribe*(c: var CallerConn, id: uint64): Result[seq[byte], string] =
  ## [SPEC TRANSPORT §5.1] At most one control operation per id is outstanding.
  if c.state == csClosed:
    return err("the connection is closed")
  var found = false
  c.subs.withValue(id, s):
    if s.active and s.pending.isNone:
      s.pending = Opt.some(mkUnsubscribe)
      found = true
  if not found:
    return err("subscription " & $id & " is not active or has an operation outstanding")
  ok(encodeCbor(toCbor(Message(kind: mkUnsubscribe, unsubscribe: Unsubscribe(id: id)))))

proc onResponse(c: var CallerConn, r: Response): seq[CallerEvent] =
  var methodName: string
  if not c.pending.pop(r.id, methodName):
    if r.id in c.abandoned:
      # [IMPL-DECISION G31] A late reply to an abandoned call.
      c.abandoned.excl(r.id)
      return @[]
    # [IMPL-DECISION G31] Never sent, or already answered.
    return c.shut(closing(ecInvalidParams, "a Response for no pending request"))
  let checked = c.boundary.acceptResponse(methodName, r)
  if checked.isErr:
    # [IMPL-DECISION G36] The waiting call gets TRANSPORT_ERROR (from `shut`).
    c.pending[r.id] = methodName
    return c.shut(closing(ecInvalidParams, checked.error.msg))
  let outcome =
    if r.ok:
      Outcome(ok: true, response: r.resultMap)
    else:
      Outcome(ok: false, failure: r.failure)
  @[CallerEvent(id: r.id, kind: ceResponse, outcome: outcome)]

proc onEvent(c: var CallerConn, e: Event): seq[CallerEvent] =
  var found = false
  c.subs.withValue(e.sub, s):
    found = s.active and s.event == e.event
  if not found:
    # [IMPL-DECISION G31] No active subscription for it.
    return c.shut(closing(ecInvalidParams, "an Event for no active subscription"))
  c.boundary.acceptEvent(e).isOkOr:
    return c.shut(closing(ecInvalidParams, error.msg))
  @[CallerEvent(id: e.sub, kind: ceEvent, event: e.event, data: e.data)]

proc onSubscriptionResult(c: var CallerConn, r: SubscriptionResult): seq[CallerEvent] =
  var matched = false
  var drop = false
  c.subs.withValue(r.id, s):
    if s.pending == Opt.some(r.operation):
      matched = true
      s.pending = Opt.none(MessageKind)
      if r.failure.isNone:
        if r.operation == mkSubscribe:
          s.active = true
        else:
          drop = true
      elif r.operation == mkSubscribe:
        drop = true
  if not matched:
    # [IMPL-DECISION G31] No such outstanding operation.
    return c.shut(closing(ecInvalidParams, "a SubscriptionResult for no operation"))
  if drop:
    c.subs.del(r.id)
  @[CallerEvent(id: r.id, kind: ceSubscription, op: r.operation, failure: r.failure)]

proc frameFailed*(c: var CallerConn, e: FrameError): seq[CallerEvent] =
  ## [SPEC TRANSPORT §2.1, §8.3] As for the callee; pending calls fail with
  ## TRANSPORT_ERROR.
  if c.state == csClosed:
    return @[]
  c.shut(closing(ecInvalidParams, "frame of " & $e.declared & " bytes over the limit"))

proc receive*(c: var CallerConn, frame: openArray[byte]): seq[CallerEvent] =
  ## One frame body from the callee.
  if c.state == csClosed:
    return @[]
  let m = decodeMessage(frame).valueOr:
    return c.shut(closing(ecInvalidParams, $error))
  case m.kind
  of mkResponse:
    c.onResponse(m.response)
  of mkEvent:
    c.onEvent(m.event)
  of mkSubscriptionResult:
    c.onSubscriptionResult(m.subscriptionResult)
  of mkHello:
    c.shut(closing(ecInvalidParams, "a Hello after establishment"))
  of mkProtocolError:
    c.shut(peerClosed(m.protocolError.code, "the callee reported an error"))
  of mkRequest, mkSubscribe, mkUnsubscribe, mkCancel:
    # [IMPL-DECISION G30]
    c.shut(closing(ecInvalidParams, "a message in the wrong direction"))
