## Lane 2 of the carrier: a hosted provider's endpoint (Tier 4b step 4b-3,
## part 4b-3.2; plan §2.7; DECISIONS G267, G273, G274) [IMPL]. Both sides use
## this module.
##
## The host serves the listener the Runtime made (fd 4) with its own
## transport I/O loop, the same loop the Runtime runs for a direct provider
## (G257). The session events that carry no payload go to the Runtime as its
## loop reports them, the provider-side `IoEvent`s, and the Runtime's session
## orders come back as provider-side `IoCommand`s. So the Runtime's own
## provider half (`served.nim`) judges every Hello, admits every call,
## subscription and delivery, keeps the sessions and writes the call records,
## for a hosted endpoint as for one it serves (K1, K2).
##
## Payloads never cross (plan §2.7, the owner's direct layout of 2026-11-14):
## a Request's params stay in the host, which commits its Responses, Events
## and introspection answers itself (`host/endpoint.nim`). So `toEvent` takes
## no params and `toMessage` refuses every command that would carry a payload
## or commit a success: a successful `cmdRespond`, `cmdPublishConn`,
## `cmdPublishScoped`, `cmdPublish` and `cmdIntrospect` are not sent to a host.
##
## The host's connection numbers become the Runtime's in `toEvent` and
## return in `toMessage` (`hostnum.nim`).

{.push raises: [], gcsafe.}

import results
import ../hash/hashinput
import ../iface/outcome
import ../transport/io/api
from ../transport/envelope import PayloadCommitment
import ./[carrier, hostnum]

export hostnum

const MessageCapacity = 512 ## `tstr .size (0..512)` in the schema

# The transport limits --------------------------------------------------------------------

func transportWords*(c: TransportConfig): seq[uint64] =
  ## [IMPL] `init.transport`: every field of `c`, in declaration order.
  for _, v in c.fieldPairs:
    when v is SomeSignedInt:
      result.add(cast[uint64](int64(v)))
    else:
      result.add(uint64(v))

func transportOf*(words: openArray[uint64]): Result[TransportConfig, string] =
  ## The limits `transportWords` gave, checked as the Runtime checks its own.
  var c: TransportConfig
  var i = 0
  for name, v in c.fieldPairs:
    if i >= words.len:
      return err("the transport limits are cut short")
    let w = words[i]
    when v is SomeSignedInt:
      let s = cast[int64](w)
      if s < int64(low(typeof(v))) or s > int64(high(typeof(v))):
        return err("the transport limit " & name & " is out of range")
      v = typeof(v)(s)
    else:
      if w > uint64(high(typeof(v))):
        return err("the transport limit " & name & " is out of range")
      v = typeof(v)(w)
    inc i
  if i != words.len:
    return err("the transport limits have " & $words.len & " values, not " & $i)
  ?c.validate()
  ok(c)

# Shared pieces ---------------------------------------------------------------------------

func clipped(s: string): string =
  if s.len > MessageCapacity:
    s[0 ..< MessageCapacity]
  else:
    s

func errorCodeOf*(c: uint8): Opt[ErrorCode] =
  ## A code a message carries; none for one outside the ABI's.
  if c > 0 and c <= uint8(high(ErrorCode)):
    Opt.some(ErrorCode(c))
  else:
    Opt.none(ErrorCode)

func digests(x: Opt[seq[Digest]]): Opt[seq[seq[byte]]] =
  if x.isNone:
    return Opt.none(seq[seq[byte]])
  var r: seq[seq[byte]]
  for d in x.get:
    r.add(@d)
  Opt.some(r)

func digestOf*(b: openArray[byte]): Opt[Digest] =
  if b.len != DigestLen:
    return Opt.none(Digest)
  var d: Digest
  for i in 0 ..< DigestLen:
    d[i] = b[i]
  Opt.some(d)

func digestsOf(x: Opt[seq[seq[byte]]]): Result[Opt[seq[Digest]], string] =
  if x.isNone:
    return ok(Opt.none(seq[Digest]))
  var r: seq[Digest]
  for b in x.get:
    let d = digestOf(b).valueOr:
      return err("a route access root is not a digest")
    r.add(d)
  ok(Opt.some(r))

func toCarrier*(c: PayloadCommitment): LcnCarrierCommitment =
  LcnCarrierCommitment(subtree_root: @(c.subtreeRoot), value_root: @(c.valueRoot))

func commitmentOf*(c: LcnCarrierCommitment): Result[PayloadCommitment, string] =
  ## A commitment a host reported; an error breaks the protocol.
  let s = digestOf(c.subtree_root).valueOr:
    return err("a commitment root that is not a digest")
  let v = digestOf(c.value_root).valueOr:
    return err("a commitment root that is not a digest")
  ok(PayloadCommitment(subtreeRoot: s, valueRoot: v))

# The host -> the Runtime: the loop's events ----------------------------------------------

func toMessage*(ev: IoEvent): Opt[LcnCarrierMessage] =
  ## Host: the message forwarding `ev`; none for an event the Runtime does not
  ## take from a host (the caller side, the serve outcome, the loop's own end).
  type K = IoEventKind
  let m =
    case ev.kind
    of K.evHello:
      toMessage(LcnCarrierIoHello(conn: ev.conn, frame: ev.frame))
    of K.evEstablished:
      toMessage(LcnCarrierIoEstablished(conn: ev.conn))
    of K.evDispatch:
      toMessage(
        LcnCarrierIoDispatch(
          conn: ev.conn,
          request: ev.requestId,
          `method`: ev.methodName,
          introspection: ev.introspection,
        )
      )
    of K.evStop:
      toMessage(LcnCarrierIoStop(conn: ev.conn, request: ev.stopId))
    of K.evClosed:
      toMessage(LcnCarrierIoClosed(conn: ev.conn))
    of K.evSubscribe:
      toMessage(
        LcnCarrierIoSubscribe(
          conn: ev.conn, sub: ev.subscribeId, event: ev.subscribeEvent
        )
      )
    of K.evUnsubscribe:
      toMessage(LcnCarrierIoUnsubscribe(conn: ev.conn, sub: ev.subscribeId))
    of K.evPublishFailed:
      toMessage(
        LcnCarrierIoPublishFailed(
          conn: ev.conn, event: ev.pubFailEvent, message: clipped(ev.pubFailMsg)
        )
      )
    of K.evPublishResult:
      var r = LcnCarrierIoPublishResult(
        conn: ev.conn, tag: ev.pubResultTag, request: ev.pubResultRequest
      )
      if ev.pubResultFailure.isSome:
        let f = ev.pubResultFailure.get
        r.failure = Opt.some(
          LcnCarrierPublishFailure(
            error: uint8(ord(f.kind)), code: uint8(ord(f.code)), message: clipped(f.msg)
          )
        )
      toMessage(r)
    of K.evLocalFailure:
      toMessage(
        LcnCarrierIoLocalFailure(
          conn: ev.conn, code: uint8(ord(ev.localCode)), message: clipped(ev.localMsg)
        )
      )
    else:
      return Opt.none(LcnCarrierMessage)
  Opt.some(m)

func toEvent*(m: LcnCarrierMessage, index: uint64): Result[Opt[IoEvent], string] =
  ## Runtime: the event a host's message forwards, in the Runtime's numbers;
  ## none for a message that is not one; an error breaks the protocol.
  type K = LcnCarrierMessageKind
  template conn(c: uint64): ConnId =
    hostedConn(index, c).valueOr:
      return err("a connection number no loop gives")

  let ep = hostedEndpoint(index)
  let ev =
    case m.kind
    of K.lcn_Carrier_io_hello:
      let x = m.arm_lcn_Carrier_io_hello
      IoEvent(
        conn: conn(x.conn), kind: IoEventKind.evHello, helloEndpoint: ep, frame: x.frame
      )
    of K.lcn_Carrier_io_established:
      IoEvent(
        conn: conn(m.arm_lcn_Carrier_io_established.conn),
        kind: IoEventKind.evEstablished,
        endpoint: ep,
      )
    of K.lcn_Carrier_io_dispatch:
      let x = m.arm_lcn_Carrier_io_dispatch
      IoEvent(
        conn: conn(x.conn),
        kind: IoEventKind.evDispatch,
        requestId: x.request,
        methodName: x.`method`,
        introspection: x.introspection,
      )
    of K.lcn_Carrier_io_stop:
      let x = m.arm_lcn_Carrier_io_stop
      IoEvent(conn: conn(x.conn), kind: IoEventKind.evStop, stopId: x.request)
    of K.lcn_Carrier_io_closed:
      IoEvent(
        conn: conn(m.arm_lcn_Carrier_io_closed.conn),
        kind: IoEventKind.evClosed,
        cause: ccPeerClosed,
      )
    of K.lcn_Carrier_io_subscribe:
      let x = m.arm_lcn_Carrier_io_subscribe
      IoEvent(
        conn: conn(x.conn),
        kind: IoEventKind.evSubscribe,
        subscribeId: x.sub,
        subscribeEvent: x.event,
      )
    of K.lcn_Carrier_io_unsubscribe:
      let x = m.arm_lcn_Carrier_io_unsubscribe
      IoEvent(conn: conn(x.conn), kind: IoEventKind.evUnsubscribe, subscribeId: x.sub)
    of K.lcn_Carrier_io_publish_failed:
      let x = m.arm_lcn_Carrier_io_publish_failed
      IoEvent(
        conn: conn(x.conn),
        kind: IoEventKind.evPublishFailed,
        pubFailEvent: x.event,
        pubFailMsg: x.message,
      )
    of K.lcn_Carrier_io_publish_result:
      let x = m.arm_lcn_Carrier_io_publish_result
      var f = Opt.none(PublishFailure)
      if x.failure.isSome:
        let y = x.failure.get
        if y.error > uint8(ord(high(PublishErrorKind))):
          return err("a publication failure of no known kind")
        let code = errorCodeOf(y.code).valueOr:
          return err("a publication failure with no valid code")
        f = Opt.some(
          PublishFailure(kind: PublishErrorKind(y.error), code: code, msg: y.message)
        )
      IoEvent(
        conn: conn(x.conn),
        kind: IoEventKind.evPublishResult,
        pubResultTag: x.tag,
        pubResultRequest: x.request,
        pubResultFailure: f,
      )
    of K.lcn_Carrier_io_local_failure:
      let x = m.arm_lcn_Carrier_io_local_failure
      IoEvent(
        conn: conn(x.conn),
        kind: IoEventKind.evLocalFailure,
        localCode: errorCodeOf(x.code).get(ecTransport),
        localMsg: x.message,
      )
    else:
      return ok(Opt.none(IoEvent))
  ok(Opt.some(ev))

# The Runtime -> the host: the loop's orders ----------------------------------------------

func toMessage*(cmd: IoCommand): Opt[LcnCarrierMessage] =
  ## Runtime: the message carrying `cmd` to its host, in the host's numbers;
  ## none for a command a host's loop does not take, and for every command
  ## that would carry a payload to it: the host commits those itself.
  type K = IoCommandKind
  let c = hostConnOf(cmd.conn)
  let m =
    case cmd.kind
    of K.cmdAdmit:
      let v = cmd.verdict
      case v.kind
      of avUnavailable:
        toMessage(LcnCarrierIoAdmitUnavailable(conn: c))
      of avFailed:
        toMessage(
          LcnCarrierIoAdmitFailed(conn: c, code: uint8(ord(v.code)), peer: v.peer)
        )
      of avEstablished:
        # Only the contract and the access reach the host (RUN-0175).
        let a = v.binding.access
        toMessage(
          LcnCarrierIoAdmitEstablished(
            conn: c,
            response: v.response,
            contract: @(v.binding.contract),
            methods: digests(a.methods),
            publish_events: digests(a.publishEvents),
            subscribe_events: digests(a.subscribeEvents),
            ends_in:
              if v.endsIn.isSome:
                Opt.some(uint64(max(v.endsIn.get, 0'i64)))
              else:
                Opt.none(uint64),
          )
        )
    of K.cmdRespond:
      if cmd.outcome.ok:
        return Opt.none(LcnCarrierMessage)
      toMessage(
        LcnCarrierIoRespond(
          conn: c,
          request: cmd.requestId,
          failure: toCarrier(cmd.outcome.failure),
          work_ended: cmd.workEnded,
        )
      )
    of K.cmdClose:
      toMessage(LcnCarrierIoClose(conn: c))
    of K.cmdTerminate:
      toMessage(LcnCarrierIoTerminate(conn: c))
    of K.cmdWorkEnded:
      toMessage(LcnCarrierIoWorkEnded(conn: c, request: cmd.endedId))
    of K.cmdSubscriptionResult:
      var r = LcnCarrierIoSubscriptionResult(conn: c, sub: cmd.subId)
      if cmd.subFailure.isSome:
        r.failure = Opt.some(toCarrier(cmd.subFailure.get))
      toMessage(r)
    of K.cmdStopServing:
      toMessage(LcnCarrierIoStopServing())
    else:
      return Opt.none(LcnCarrierMessage)
  Opt.some(m)

func toCommand*(m: LcnCarrierMessage): Result[Opt[IoCommand], string] =
  ## Host: the order a Runtime message gives the loop; none for a message that
  ## is not one; an error breaks the protocol.
  type K = LcnCarrierMessageKind
  let cmd =
    case m.kind
    of K.lcn_Carrier_io_admit_established:
      let x = m.arm_lcn_Carrier_io_admit_established
      let contract = digestOf(x.contract).valueOr:
        return err("a selected contract that is not a digest")
      let
        methods = ?digestsOf(x.methods)
        publishEvents = ?digestsOf(x.publish_events)
        subscribeEvents = ?digestsOf(x.subscribe_events)
        access = RouteAccess(
          methods: methods,
          publishEvents: publishEvents,
          subscribeEvents: subscribeEvents,
        )
      IoCommand(
        conn: x.conn,
        kind: IoCommandKind.cmdAdmit,
        verdict: AdmitVerdict(
          kind: avEstablished,
          response: x.response,
          binding: RouteBinding(contract: contract, access: access),
          endsIn:
            if x.ends_in.isSome:
              Opt.some(int64(min(x.ends_in.get, uint64(high(int64)))))
            else:
              Opt.none(int64),
        ),
      )
    of K.lcn_Carrier_io_admit_failed:
      let x = m.arm_lcn_Carrier_io_admit_failed
      let code = errorCodeOf(x.code).valueOr:
        return err("a Hello verdict with no valid code")
      IoCommand(
        conn: x.conn,
        kind: IoCommandKind.cmdAdmit,
        verdict: AdmitVerdict(kind: avFailed, code: code, peer: x.peer),
      )
    of K.lcn_Carrier_io_admit_unavailable:
      IoCommand(
        conn: m.arm_lcn_Carrier_io_admit_unavailable.conn,
        kind: IoCommandKind.cmdAdmit,
        verdict: AdmitVerdict(kind: avUnavailable),
      )
    of K.lcn_Carrier_io_respond:
      let x = m.arm_lcn_Carrier_io_respond
      IoCommand(
        conn: x.conn,
        kind: IoCommandKind.cmdRespond,
        requestId: x.request,
        outcome: CallOutcome(ok: false, failure: toInvocation(x.failure)),
        workEnded: x.work_ended,
      )
    of K.lcn_Carrier_io_close:
      IoCommand(conn: m.arm_lcn_Carrier_io_close.conn, kind: IoCommandKind.cmdClose)
    of K.lcn_Carrier_io_terminate:
      IoCommand(
        conn: m.arm_lcn_Carrier_io_terminate.conn, kind: IoCommandKind.cmdTerminate
      )
    of K.lcn_Carrier_io_work_ended:
      let x = m.arm_lcn_Carrier_io_work_ended
      IoCommand(conn: x.conn, kind: IoCommandKind.cmdWorkEnded, endedId: x.request)
    of K.lcn_Carrier_io_subscription_result:
      let x = m.arm_lcn_Carrier_io_subscription_result
      var f = Opt.none(InvocationFailure)
      if x.failure.isSome:
        f = Opt.some(toInvocation(x.failure.get))
      IoCommand(
        conn: x.conn,
        kind: IoCommandKind.cmdSubscriptionResult,
        subId: x.sub,
        subFailure: f,
      )
    of K.lcn_Carrier_io_stop_serving:
      IoCommand(kind: IoCommandKind.cmdStopServing, stopEndpoint: HostEndpoint)
    else:
      return ok(Opt.none(IoCommand))
  ok(Opt.some(cmd))
