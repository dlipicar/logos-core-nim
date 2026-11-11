## TRANSPORT §1.4, §2.1, §2.3, §3.2–§3.4, §4, §5.1, §6, §7, §8.1, §8.6: one
## established connection, for each side, as a pure state machine. Each
## received frame body yields actions (dispatch, send these bytes, stop,
## close); each local operation yields the bytes to send, or a local failure
## when nothing may be sent. No I/O, no clocks. The per-connection limits and
## their behaviour on exhaustion are documented in `limits.nim`.

{.push raises: [].}

import std/[algorithm, sets, tables]
import results
import ../cbor
import ./[boundary, envelope, framing, limits]

export results, boundary, envelope, framing, limits

type
  ConnState* = enum
    csOpen
    csTerminating
      ## callee only: the route expired or was revoked; admission has stopped
      ## and `finishTermination` closes (§8.1)
    csClosed

  CloseReason* = object
    ## Why a connection closed. `send` is the ProtocolError to send first when
    ## the connection is still writable; none when the peer closed or reported.
    send*: Opt[seq[byte]]
    code*: ErrorCode
    msg*: string

  LocalFailure* = object
    ## A local operation that sent nothing and consumed no identifier: the
    ## caller's invocation or subscription fails with `code`.
    code*: ErrorCode
    msg*: string

func protocolError(code: ErrorCode): seq[byte] =
  ## [SPEC TRANSPORT §1.3, §2.3] A ProtocolError without message or detail, so
  ## a depth rejection never carries detail and an authorization one discloses
  ## nothing (§8.1).
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

func localFailure(code: ErrorCode, msg: string): LocalFailure =
  LocalFailure(code: code, msg: msg)

func encoded(m: Message): seq[byte] =
  encodeCbor(toCbor(m))

func responseErr(id: uint64, f: InvocationFailure): seq[byte] =
  encoded(Message(kind: mkResponse, response: Response(id: id, ok: false, failure: f)))

func subResult(id: uint64, op: MessageKind, f: Opt[InvocationFailure]): seq[byte] =
  encoded(
    Message(
      kind: mkSubscriptionResult,
      subscriptionResult: SubscriptionResult(id: id, operation: op, failure: f),
    )
  )

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
    pending: Opt[MessageKind] ## an operation whose result is not committed yet

  PublishErrorKind* = enum
    ## Why an Event was not committed. `code` maps each to the INTERFACE §2.9.3
    ## outcome of a publication boundary that has a result.
    peClosed ## the connection is closed
    peEnded ## the route's access ended: the session is terminating (§8.1)
    peNoDestination
      ## no active subscription with that id, or (scoped) the invocation's
      ## terminal Response or CANCELLED is already committed (§6)
    peNotInContract ## the event is not in the selected contract
    peInvalid ## the data fails its declaration, holds a float or nests deeper than P
    peTooLarge ## the Event does not fit the peer's frame maximum: not committed (§2.1)

  PublishError* = object
    kind*: PublishErrorKind
    msg*: string

  CalleeConn* = object ## The callee side of one established provider session.
    boundary*: Boundary
    state*: ConnState
    limits: TransportLimits
    highestId: Opt[uint64] ## the highest Request id received (§7)
    inFlight: Table[uint64, string] ## Request id -> method, until committed
    subs: Table[uint64, CalleeSub]
    usedSubIds: HashSet[uint64]
      ## every id of a valid Subscribe on this connection (§5.1)

func code*(e: PublishError): ErrorCode =
  ## [SPEC INTERFACE §2.9.3] The result of a publication boundary that has one;
  ## an oversized Event is MODULE_ERROR there, as an oversized Request is
  ## (TRANSPORT §2.1) [IMPL]. Without a result channel (`logos_publish_fn`),
  ## `peTooLarge` is TRANSPORT §2.1's ProtocolError TRANSPORT_ERROR and close;
  ## whether RUNTIME §7.3's drop covers it is an open question to the owner.
  case e.kind
  of peClosed: ecTransport
  of peEnded: ecNotAuthorised
  of peNoDestination: ecNotReady
  of peNotInContract: ecNotAuthorised
  of peInvalid: ecInvalidParams
  of peTooLarge: ecModule

func publishError(kind: PublishErrorKind, msg: string): PublishError =
  PublishError(kind: kind, msg: msg)

func calleeConn*(b: Boundary, limits = defaultLimits()): CalleeConn =
  CalleeConn(boundary: b, state: csOpen, limits: limits)

func limits*(c: CalleeConn): TransportLimits =
  c.limits

func inFlight*(c: CalleeConn): int =
  c.inFlight.len

func subscriptions*(c: CalleeConn): int =
  ## Subscriptions held: active, or with a Subscribe outstanding.
  c.subs.len

func usedSubscriptionIds*(c: CalleeConn): int =
  c.usedSubIds.len

func admitsInput*(c: CalleeConn): bool =
  ## [SPEC TRANSPORT §8.6] Whether the carrier should read the next frame. False
  ## once closed, and while `maxInFlight` Requests are admitted and unanswered:
  ## the carrier then stops reading (backpressure) until a Response is
  ## committed. Input is never read and dropped.
  c.state != csClosed and c.inFlight.len < c.limits.maxInFlight

func send(bytes: seq[byte]): CalleeAction =
  CalleeAction(kind: caSend, bytes: bytes)

proc close(c: var CalleeConn, r: CloseReason): seq[CalleeAction] =
  ## [SPEC TRANSPORT §3.2] Closing ends every subscription; in-flight requests
  ## are abandoned (their callers see TRANSPORT_ERROR).
  c.state = csClosed
  c.inFlight.clear()
  c.subs.clear()
  @[CalleeAction(kind: caClose, close: r)]

func pendingOp(c: CalleeConn, id: uint64): bool =
  var p = false
  c.subs.withValue(id, s):
    p = s.pending.isSome
  p

proc onRequest(c: var CalleeConn, r: Request): seq[CalleeAction] =
  # [SPEC TRANSPORT §7] Request ids strictly increase on a connection.
  if c.highestId.isSome and r.id <= c.highestId.get:
    return c.close(closing(ecInvalidParams, "a Request id did not increase"))
  c.highestId = Opt.some(r.id)
  if c.state == csTerminating:
    # [SPEC TRANSPORT §8.1] Committed now, without dispatch, and with nothing
    # that discloses the authorization condition.
    return @[send(responseErr(r.id, failureOf(ecNotAuthorised)))]
  if c.inFlight.len >= c.limits.maxInFlight:
    # [SPEC TRANSPORT §8.6] Read past `admitsInput`: refuse the connection
    # rather than drop an accepted Request [IMPL].
    return c.close(closing(ecTransport, "more Requests in flight than maxInFlight"))
  let checked = c.boundary.acceptRequest(r)
  if checked.isErr:
    let rj = checked.error
    case rj.kind
    of rjClose:
      return c.close(closing(rj.failure.code, rj.msg))
    of rjRespond:
      # Committed now: the call fails as it would in direct mode; nothing runs.
      return @[send(responseErr(r.id, rj.failure))]
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
  ## CANCELLED Response at once, without waiting for the provider to stop, and
  ## try to stop the operation; its scoped publication ends. Otherwise ignore
  ## it, with no reply and no state change.
  if id notin c.inFlight:
    return @[]
  c.inFlight.del(id)
  @[send(responseErr(id, failureOf(ecCancelled))), CalleeAction(kind: caStop, id: id)]

proc onSubscribe(c: var CalleeConn, s: Subscribe): seq[CalleeAction] =
  ## [SPEC TRANSPORT §5.1] The overlap check, then the identifier check, before
  ## the event name is resolved or its access checked. The id is used from here
  ## on, whatever the outcome.
  if c.pendingOp(s.id):
    return
      c.close(closing(ecInvalidParams, "a Subscribe overlaps an uncommitted result"))
  if s.id in c.usedSubIds:
    return @[send(subResult(s.id, mkSubscribe, Opt.some(failureOf(ecInvalidParams))))]
  if c.usedSubIds.len >= c.limits.maxSubscriptionIds:
    # [SPEC TRANSPORT §5.1, §8.6] Close rather than forget an id.
    return c.close(closing(ecTransport, "the subscription-id history is full"))
  c.usedSubIds.incl(s.id)
  if c.state == csTerminating or not c.boundary.knowsEvent(s.event) or
      not c.boundary.allowsEvent(s.event):
    # Resolved under the selected contract only, then the route's subscription
    # scope (§8.1); during termination that access has ended [IMPL].
    return @[send(subResult(s.id, mkSubscribe, Opt.some(failureOf(ecNotAuthorised))))]
  c.subs[s.id] = CalleeSub(event: s.event, pending: Opt.some(mkSubscribe))
  @[CalleeAction(kind: caSubscribe, subId: s.id, event: s.event)]

proc onUnsubscribe(c: var CalleeConn, id: uint64): seq[CalleeAction] =
  ## [SPEC TRANSPORT §5.1] An operation over an uncommitted result closes; an
  ## id with no active subscription fails with INVALID_PARAMS and changes
  ## nothing.
  if c.pendingOp(id):
    return
      c.close(closing(ecInvalidParams, "an Unsubscribe overlaps an uncommitted result"))
  var found = false
  c.subs.withValue(id, s):
    if s.active:
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
  let m = decodeMessage(frame, c.limits.payloadDepth).valueOr:
    # [SPEC TRANSPORT §2.3, §8.3, §10] A float anywhere and a payload deeper
    # than P included; the ProtocolError carries no detail.
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
    # [SPEC TRANSPORT §2.3] Close without sending another ProtocolError.
    c.close(peerClosed(m.protocolError.code, "the caller reported an error"))
  of mkResponse, mkEvent, mkSubscriptionResult:
    # [SPEC TRANSPORT §1.4, §2.3] A callee-to-caller kind from the caller.
    c.close(closing(ecInvalidParams, "a message in the wrong direction"))

proc respond*(c: var CalleeConn, id: uint64, outcome: Outcome): Opt[seq[byte]] =
  ## [SPEC TRANSPORT §2.1, §4.1, §6] The one terminal Response of request `id`,
  ## or none when its Response is already committed (CANCELLED) or the
  ## connection is closed. A provider response outside its schema (a float or a
  ## payload deeper than P included) is MODULE_ERROR, as in direct mode
  ## (INTERFACE §4.3). A success Response that does not fit the peer's frame
  ## maximum is replaced by response-err MODULE_ERROR without detail and the
  ## session stays; an error Response always fits (a code, at most 512 bytes of
  ## message and 4096 of detail). During termination in-flight Requests can
  ## still be answered (§8.1, RUNTIME §9.3).
  if c.state == csClosed:
    return Opt.none(seq[byte])
  var methodName: string
  if not c.inFlight.pop(id, methodName):
    return Opt.none(seq[byte])
  var resp: Response
  if outcome.ok:
    checkPayload(outcome.response, c.limits.payloadDepth).isOkOr:
      return Opt.some(responseErr(id, failureOf(ecModule)))
    let commitment = c.boundary.commitResponse(methodName, outcome.response).valueOr:
      return Opt.some(responseErr(id, failureOf(ecModule)))
    resp =
      Response(id: id, ok: true, resultMap: outcome.response, commitment: commitment)
  elif checkFailure(outcome.failure).isOk:
    resp = Response(id: id, ok: false, failure: outcome.failure)
  else:
    # A failure the envelope cannot carry (code 0, an over-long message,
    # detail its code does not allow) is the module's fault [IMPL].
    resp = Response(id: id, ok: false, failure: failureOf(ecModule))
  let bytes = encoded(Message(kind: mkResponse, response: resp))
  if not fits(bytes.len, c.limits.peerFrameLimit):
    return Opt.some(responseErr(id, failureOf(ecModule)))
  Opt.some(bytes)

proc subscriptionResult*(
    c: var CalleeConn, id: uint64, failure = Opt.none(InvocationFailure)
): Opt[seq[byte]] =
  ## [SPEC TRANSPORT §5.1] Completes the outstanding operation of `id`. A failure
  ## leaves the active subscription state unchanged; the id stays used.
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

func eventBytes(
    c: CalleeConn, sub: uint64, event: string, data: CborValue, cm: PayloadCommitment
): Result[seq[byte], PublishError] =
  let bytes = encoded(
    Message(
      kind: mkEvent, event: Event(sub: sub, event: event, data: data, commitment: cm)
    )
  )
  if not fits(bytes.len, c.limits.peerFrameLimit):
    return err(
      publishError(
        peTooLarge,
        "an Event of " & $bytes.len & " bytes does not fit the peer's frame maximum",
      )
    )
  ok(bytes)

func commitData(
    c: CalleeConn, event: string, data: CborValue
): Result[PayloadCommitment, PublishError] =
  checkPayload(data, c.limits.payloadDepth).isOkOr:
    return err(publishError(peInvalid, error.msg))
  let cm = c.boundary.commitEvent(event, data).valueOr:
    return err(
      publishError(
        if error.cause == rcUnknownTarget: peNotInContract else: peInvalid, error.msg
      )
    )
  ok(cm)

func checkOpen(c: CalleeConn): Result[void, PublishError] =
  case c.state
  of csClosed:
    err(publishError(peClosed, "the connection is closed"))
  of csTerminating:
    err(publishError(peEnded, "the route's access has ended"))
  of csOpen:
    ok()

proc publish*(
    c: var CalleeConn, id: uint64, data: CborValue
): Result[seq[byte], PublishError] =
  ## [SPEC TRANSPORT §2.1, §4.1, §5.1] An Event for active subscription `id`,
  ## with its payload commitment. Nothing is committed before the successful
  ## result, after a successful Unsubscribe or once the route's access ended,
  ## and an Event that does not fit the peer's frame maximum is not committed
  ## (`peTooLarge`).
  ?c.checkOpen()
  var event = ""
  var active = false
  c.subs.withValue(id, s):
    active = s.active
    event = s.event
  if not active:
    return err(publishError(peNoDestination, "no active subscription " & $id))
  let cm = ?c.commitData(event, data)
  c.eventBytes(id, event, data, cm)

proc publishScoped*(
    c: var CalleeConn, reqId: uint64, event: string, data: CborValue
): Result[seq[seq[byte]], PublishError] =
  ## [SPEC TRANSPORT §5.2, §6; RUNTIME §7.3.1] Invocation-scoped publication
  ## through the destination of request `reqId`: one Event per active
  ## subscription to `event` on this connection, in subscription-id order, and
  ## none when there is no such subscription. The destination closes when the
  ## request's terminal Response or CANCELLED is committed: later publications
  ## fail (`peNoDestination`), and earlier Events stay committed. The Events
  ## carry no request id. Every Event must fit, or none is committed on this
  ## connection (`peTooLarge`).
  ?c.checkOpen()
  if reqId notin c.inFlight:
    return err(
      publishError(peNoDestination, "request " & $reqId & " is no longer in flight")
    )
  let cm = ?c.commitData(event, data)
  var ids: seq[uint64]
  for id, s in c.subs:
    if s.active and s.event == event:
      ids.add(id)
  ids.sort()
  var frames: seq[seq[byte]]
  for id in ids:
    frames.add(?c.eventBytes(id, event, data, cm))
  ok(frames)

proc beginTermination*(c: var CalleeConn): seq[CalleeAction] =
  ## [SPEC TRANSPORT §8.1, §8.1.2] The route (or system-service binding)
  ## expired or was revoked: admission stops. A new Request gets a committed
  ## response-err NOT_AUTHORISED without dispatch; a new Subscribe a failed
  ## result NOT_AUTHORISED [IMPL]. Every subscription ends and no Event is
  ## committed after this; an outstanding Subscribe fails with NOT_AUTHORISED
  ## and an outstanding Unsubscribe succeeds [IMPL], so each operation still
  ## gets its one result (§5.1). In-flight Requests stay for the Runtime's
  ## in-flight policy (RUNTIME §9.3): they can still be answered or cancelled.
  ## `finishTermination` then closes; it waits for no further input.
  if c.state != csOpen:
    return @[]
  c.state = csTerminating
  var ops: seq[(uint64, MessageKind)]
  for id, s in c.subs:
    if s.pending.isSome:
      ops.add((id, s.pending.get))
  ops.sort()
  var acts: seq[CalleeAction]
  for (id, op) in ops:
    acts.add(
      send(
        if op == mkSubscribe:
          subResult(id, op, Opt.some(failureOf(ecNotAuthorised)))
        else:
          subResult(id, op, Opt.none(InvocationFailure))
      )
    )
  c.subs.clear()
  acts

proc finishTermination*(c: var CalleeConn): seq[CalleeAction] =
  ## [SPEC TRANSPORT §8.1] ProtocolError NOT_AUTHORISED, with no message or
  ## detail, when writable, then close. Callable at once after
  ## `beginTermination`: termination neither waits for another Request nor
  ## reads the unread ones. Requests still in flight are abandoned; their callers
  ## get TRANSPORT_ERROR (§3.2).
  if c.state == csClosed:
    return @[]
  c.close(closing(ecNotAuthorised, "the route's authorization ended"))

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
    abandoned: bool ## local delivery given up: Events are validated, not delivered

  CallerConn* = object ## The caller side of one established provider session.
    boundary*: Boundary
    state*: ConnState
    limits: TransportLimits
    lastId: Opt[uint64] ## the last Request id transmitted
    pending: Table[uint64, string] ## Request id -> method, awaited
    abandoned: Table[uint64, string]
      ## Request id -> method: transmitted, no longer awaited, no terminal
      ## Response received yet (§3.4)
    subs: Table[uint64, CallerSub]
    usedSubIds: HashSet[uint64] ## every id sent in a Subscribe (§5.1)

func callerConn*(b: Boundary, firstId = 0'u64, limits = defaultLimits()): CallerConn =
  ## `firstId` is the first Request id; later ones are each one larger.
  var c = CallerConn(boundary: b, state: csOpen, limits: limits)
  if firstId > 0:
    c.lastId = Opt.some(firstId - 1)
  c

func limits*(c: CallerConn): TransportLimits =
  c.limits

func pendingCalls*(c: CallerConn): int =
  ## Calls whose terminal Response is awaited.
  c.pending.len

func outstandingCalls*(c: CallerConn): int =
  ## Transmitted Requests with no terminal Response received, abandoned ones
  ## included: the correlation state `maxCalls` bounds.
  c.pending.len + c.abandoned.len

proc shut(c: var CallerConn, r: CloseReason): seq[CallerEvent] =
  ## [SPEC TRANSPORT §3.2] Every pending call fails with a synthetic
  ## TRANSPORT_ERROR and every subscription ends. Requests are not replayed.
  var ids: seq[uint64]
  for id, _ in c.pending:
    ids.add(id)
  ids.sort()
  var events: seq[CallerEvent]
  for id in ids:
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
): Result[(uint64, seq[byte]), LocalFailure] =
  ## [SPEC TRANSPORT §2.1, §4.1, §7, §8.6] A Request with the next id and the
  ## commitment of its validated params. Nothing is sent, and no id consumed,
  ## when the connection is closed (NOT_READY, [IMPL-DECISION G22]), `maxCalls`
  ## calls are outstanding (MODULE_ERROR), the method is not in the selected
  ## contract (METHOD_NOT_FOUND), the params fail it (INVALID_PARAMS), or the
  ## Request does not fit the peer's frame maximum (MODULE_ERROR). With no
  ## larger id left, the connection closes and nothing is sent.
  if c.state == csClosed:
    return err(localFailure(ecNotReady, "the connection is closed"))
  if c.outstandingCalls >= c.limits.maxCalls:
    return err(localFailure(ecModule, "maxCalls calls are outstanding"))
  checkPayload(params, c.limits.payloadDepth).isOkOr:
    return err(localFailure(ecInvalidParams, error.msg))
  let commitment = c.boundary.commitRequest(methodName, params).valueOr:
    return err(localFailure(error.failure.code, error.msg))
  if c.lastId == Opt.some(high(uint64)):
    discard c.shut(peerClosed(ecTransport, "no larger Request id"))
    return
      err(localFailure(ecTransport, "no larger Request id: the connection is closed"))
  let id =
    if c.lastId.isSome:
      c.lastId.get + 1
    else:
      0'u64
  let bytes = encoded(
    Message(
      kind: mkRequest,
      request:
        Request(id: id, methodName: methodName, params: params, commitment: commitment),
    )
  )
  if not fits(bytes.len, c.limits.peerFrameLimit):
    return err(
      localFailure(
        ecModule,
        "a Request of " & $bytes.len & " bytes does not fit the peer's frame maximum",
      )
    )
  c.lastId = Opt.some(id)
  c.pending[id] = methodName
  ok((id, bytes))

func cancel*(c: CallerConn, id: uint64): Opt[seq[byte]] =
  ## [SPEC TRANSPORT §6] A Cancel for a transmitted request with no terminal
  ## Response yet, awaited or abandoned. It still gets exactly one Response:
  ## CANCELLED or the one already committed.
  if c.state == csClosed or (id notin c.pending and id notin c.abandoned):
    return Opt.none(seq[byte])
  Opt.some(encoded(Message(kind: mkCancel, cancel: Cancel(id: id))))

proc abandon*(c: var CallerConn, id: uint64): bool =
  ## [SPEC TRANSPORT §3.4] Gives up on a pending request (a local timeout). Its
  ## protocol state stays: the first late Response is still validated, then
  ## discarded, and only then is the id retired.
  var methodName: string
  if not c.pending.pop(id, methodName):
    return false
  c.abandoned[id] = methodName
  true

proc abandonSubscription*(c: var CallerConn, id: uint64): bool =
  ## [SPEC TRANSPORT §3.4] Gives up local delivery for subscription `id`: its
  ## Events are still validated, then discarded instead of reported, and its
  ## SubscriptionResults still update the protocol state. Only `unsubscribe`
  ## (once no operation is outstanding) or closing stops it.
  var found = false
  c.subs.withValue(id, s):
    s.abandoned = true
    found = true
  found

proc subscribe*(
    c: var CallerConn, id: uint64, event: string
): Result[seq[byte], LocalFailure] =
  ## [SPEC TRANSPORT §5.1] A Subscribe with an id unused on this connection for
  ## an event of the selected contract. Nothing is sent when the connection is
  ## closed (NOT_READY), the id was ever used (INVALID_PARAMS), the id history is
  ## full (MODULE_ERROR), or the event is not in the selected contract
  ## (NOT_AUTHORISED, the callee's answer) [IMPL].
  if c.state == csClosed:
    return err(localFailure(ecNotReady, "the connection is closed"))
  if id in c.usedSubIds:
    return
      err(localFailure(ecInvalidParams, "subscription id " & $id & " was already used"))
  if c.usedSubIds.len >= c.limits.maxSubscriptionIds:
    return err(localFailure(ecModule, "the subscription-id history is full"))
  if not c.boundary.knowsEvent(event):
    return err(
      localFailure(ecNotAuthorised, event & " is not an event of the selected contract")
    )
  c.usedSubIds.incl(id)
  c.subs[id] = CallerSub(event: event, pending: Opt.some(mkSubscribe))
  ok(encoded(Message(kind: mkSubscribe, subscribe: Subscribe(id: id, event: event))))

proc unsubscribe*(c: var CallerConn, id: uint64): Result[seq[byte], LocalFailure] =
  ## [SPEC TRANSPORT §5.1] At most one control operation per id is outstanding.
  if c.state == csClosed:
    return err(localFailure(ecNotReady, "the connection is closed"))
  var found = false
  c.subs.withValue(id, s):
    if s.active and s.pending.isNone:
      s.pending = Opt.some(mkUnsubscribe)
      found = true
  if not found:
    return err(
      localFailure(
        ecInvalidParams,
        "subscription " & $id & " is not active or has an operation outstanding",
      )
    )
  ok(encoded(Message(kind: mkUnsubscribe, unsubscribe: Unsubscribe(id: id))))

proc onResponse(c: var CallerConn, r: Response): seq[CallerEvent] =
  ## [SPEC TRANSPORT §3.4, §4.1] A Response must name a transmitted Request with
  ## no terminal Response received. One no longer awaited is still validated,
  ## then discarded, and its id retired; a later one is a duplicate.
  var methodName: string
  var awaited = true
  if not c.pending.pop(r.id, methodName):
    if not c.abandoned.pop(r.id, methodName):
      return c.shut(closing(ecInvalidParams, "a Response for no outstanding request"))
    awaited = false
  let checked = c.boundary.acceptResponse(methodName, r)
  if checked.isErr:
    # The waiting call gets TRANSPORT_ERROR (from `shut`).
    if awaited:
      c.pending[r.id] = methodName
    return c.shut(closing(checked.error.failure.code, checked.error.msg))
  if not awaited:
    return @[]
  let outcome =
    if r.ok:
      Outcome(ok: true, response: r.resultMap)
    else:
      Outcome(ok: false, failure: r.failure)
  @[CallerEvent(id: r.id, kind: ceResponse, outcome: outcome)]

proc onEvent(c: var CallerConn, e: Event): seq[CallerEvent] =
  ## [SPEC TRANSPORT §3.4, §4.1] An Event must name an active subscription and
  ## its event, and pass the receiving checks; an abandoned subscription's
  ## Event is then discarded.
  var found, abandoned = false
  c.subs.withValue(e.sub, s):
    found = s.active and s.event == e.event
    abandoned = s.abandoned
  if not found:
    return c.shut(closing(ecInvalidParams, "an Event for no active subscription"))
  c.boundary.acceptEvent(e).isOkOr:
    return c.shut(closing(error.failure.code, error.msg))
  if abandoned:
    return @[]
  @[CallerEvent(id: e.sub, kind: ceEvent, event: e.event, data: e.data)]

proc onSubscriptionResult(c: var CallerConn, r: SubscriptionResult): seq[CallerEvent] =
  ## [SPEC TRANSPORT §3.4, §5.1] It must match the id and operation of an
  ## outstanding Subscribe or Unsubscribe; it updates the protocol state even
  ## for an abandoned subscription.
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
  let m = decodeMessage(frame, c.limits.payloadDepth).valueOr:
    # [SPEC TRANSPORT §2.3, §8.3, §10]
    return c.shut(closing(ecInvalidParams, $error))
  case m.kind
  of mkResponse:
    c.onResponse(m.response)
  of mkEvent:
    c.onEvent(m.event)
  of mkSubscriptionResult:
    c.onSubscriptionResult(m.subscriptionResult)
  of mkHello:
    # [SPEC TRANSPORT §3.3]
    c.shut(closing(ecInvalidParams, "a Hello after establishment"))
  of mkProtocolError:
    # [SPEC TRANSPORT §2.3, §3.2, §8.1] Close without a reply; pending calls
    # get TRANSPORT_ERROR whatever the code.
    c.shut(peerClosed(m.protocolError.code, "the callee reported an error"))
  of mkRequest, mkSubscribe, mkUnsubscribe, mkCancel:
    # [SPEC TRANSPORT §1.4, §2.3]
    c.shut(closing(ecInvalidParams, "a message in the wrong direction"))
