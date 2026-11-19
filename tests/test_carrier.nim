## The carrier between the Runtime and a Module Host (`runtime/carrier.nim`;
## Tier 4b step 4b-3, DECISIONS G266; plan §2.4) [IMPL]: every message kind
## round-trips byte for byte with every optional field present and absent; a
## body that is not one message, an unknown kind or field, and a frame over
## the carrier's limit are refused; frames split at any byte boundary are
## reassembled. Portable: no socket is involved.
##
## Part 4b-3.2 (G273): a hosted provider's loop events and the Runtime's
## orders for it cross lane 2 and come back as the same event or command, in
## the Runtime's numbers on its side and the host's on the other; the caller
## side's events and commands, and the loop's own end, never cross.

import std/sequtils
import unittest2
import results
import logos_sdk/abi/checks
import logos_sdk/cbor
import logos_sdk/hash/hashinput
import logos_sdk/iface/outcome
import ../src/logos_core/runtime/[carrier, hostio]
import ../src/logos_core/transport/io/api except decodeMessage

func failure(): LcnCarrierFailure =
  LcnCarrierFailure(
    code: uint8(ord(ecModule)),
    message: Opt.some("the module refused"),
    detail: Opt.some(@[0xA0'u8]),
    reason: Opt.some("an invalid status"),
  )

proc samples(): seq[LcnCarrierMessage] =
  ## Each kind twice: every optional field absent, then present.
  type
    C = LcnCarrierInitFailedCodeChoiceKind
    P = LcnCarrierInitFailedPhaseChoiceKind

  let root = newSeq[byte](32)
  @[
    toMessage(
      LcnCarrierInit(
        id: 1, module: "probe_module", artifact_path: "/w/a.so", max_payload_depth: 64
      )
    ),
    toMessage(
      LcnCarrierInit(
        id: 2,
        module: "probe_module",
        artifact_path: "/w/a.so",
        state_dir: Opt.some("/w/state/p"),
        configuration: Opt.some(@[0xA1'u8, 0x61, 0x61, 0x01]),
        live: true,
        max_payload_depth: high(uint64),
      )
    ),
    toMessage(LcnCarrierApply(id: 3, configuration: @[0xA0'u8])),
    toMessage(LcnCarrierRelease(id: 4)),
    toMessage(LcnCarrierInitialized(id: 5)),
    toMessage(LcnCarrierInitialized(id: 6, call_surface: Opt.some(@[1'u8, 2, 3]))),
    toMessage(
      LcnCarrierInitFailed(
        id: 7,
        code: LcnCarrierInitFailedCodeChoice(kind: C.Abi_invalid),
        message: "no _MODULE_init",
        phase: LcnCarrierInitFailedPhaseChoice(kind: P.Bind),
      )
    ),
    toMessage(
      LcnCarrierInitFailed(
        id: 8,
        code: LcnCarrierInitFailedCodeChoice(kind: C.Realization_failed),
        message: "",
        phase: LcnCarrierInitFailedPhaseChoice(kind: P.Init),
        cause: Opt.some(failure()),
      )
    ),
    toMessage(LcnCarrierApplied(id: 9)),
    toMessage(LcnCarrierApplied(id: 10, failure: Opt.some(failure()))),
    toMessage(LcnCarrierReleased(id: 11)),
    toMessage(LcnCarrierFatal(message: "the lifecycle thread cannot start")),
    toMessage(
      LcnCarrierRcCall(
        id: 12, `method`: @[0x67'u8], params: @[0xA0'u8], runtime_thread: true
      )
    ),
    toMessage(LcnCarrierRcSubscribe(id: 13, event: @[0x65'u8], local: 1)),
    toMessage(LcnCarrierRcUnsubscribe(id: 14, sub: 3)),
    toMessage(LcnCarrierRcUnsubscribe(id: 15, sub: 3, in_handler: Opt.some(1'u64))),
    toMessage(LcnCarrierRcDelivered(local: 1, seq: 2)),
    toMessage(
      LcnCarrierRcConnectRemote(id: 16, endpoint: @[0xA0'u8], expected_root: root)
    ),
    toMessage(LcnCarrierRcPublish(id: 17, event: @[0x65'u8])),
    toMessage(LcnCarrierRcDeliver(id: 17, event: "meter.changed_event")),
    toMessage(
      LcnCarrierRcDeliver(
        id: 17,
        event: "meter.changed_event",
        conns: @[7'u64, 8],
        dropped: @[LcnCarrierDropped(conn: 9, code: 3)],
      )
    ),
    toMessage(LcnCarrierRcPrepare(id: 18, call: 1, `method`: @[0x67'u8], params: @[])),
    toMessage(
      LcnCarrierRcPrepare(
        id: 19,
        call: 2,
        `method`: @[0x67'u8],
        params: @[0xA0'u8],
        timeout_ms: Opt.some(5000'u64),
      )
    ),
    toMessage(LcnCarrierRcAsyncSubmit(call: 1)),
    toMessage(LcnCarrierRcAsyncCancel(call: 1)),
    toMessage(LcnCarrierRcAsyncRelease(id: 20, call: 1)),
    # A hosted consumer's route handles (part 4b-3.3).
    toMessage(
      LcnCarrierRcMaterialize(
        id: 24, route: "r-1", expected_root: root, schema: @[0xa0'u8], material: true
      )
    ),
    toMessage(LcnCarrierRcLinkResult(id: 25, link: 1)),
    toMessage(
      LcnCarrierRcLinkResult(
        id: 26, link: 1, cause: Opt.some(2'u8), code: Opt.some(uint8(ord(ecTransport)))
      )
    ),
    toMessage(
      LcnCarrierRcLinkAdmit(
        id: 27, link: 1, op: 0, name: Opt.some(@[0x67'u8]), closed: Opt.some(13'u8)
      )
    ),
    toMessage(LcnCarrierRcLinkAdmit(id: 28, link: 1, op: 3)),
    toMessage(LcnCarrierRcLinkClosed(id: 29, link: 1, code: uint8(ord(ecTransport)))),
    toMessage(LcnCarrierRcLinkReleased(id: 30, link: 1)),
    toMessage(LcnCarrierRcReply(id: 21)),
    toMessage(
      LcnCarrierRcReply(
        id: 22,
        value: Opt.some(@[0xA0'u8]),
        sub: Opt.some(4'u64),
        failure: Opt.some(failure()),
        targets: Opt.some(@[LcnCarrierTarget(conn: 7, contract: root)]),
        admitted: Opt.some(@[7'u64]),
      )
    ),
    toMessage(
      LcnCarrierRcReply(
        id: 24,
        link: Opt.some(1'u64),
        uid: Opt.some(501'u32),
        module: Opt.some("meter_module"),
        code: Opt.some(uint8(ord(ecNotReady))),
      )
    ),
    toMessage(
      LcnCarrierRcDelivery(
        local: 1,
        seq: 1,
        name: "logos.runtime_control.inventory_changed_event",
        data: @[],
      )
    ),
    toMessage(
      LcnCarrierRouteEnded(
        route: "r-1",
        code: uint8(ord(ecNotAuthorised)),
        revoked: true,
        links: @[LcnCarrierLinkFirst(link: 1, first: uint8(ord(ecTransport)))],
      )
    ),
    toMessage(
      LcnCarrierRouteEnded(
        route: "r-2", code: uint8(ord(ecNotReady)), revoked: false, links: @[]
      )
    ),
    toMessage(LcnCarrierAsyncDone(call: 1)),
    toMessage(LcnCarrierRcSubscriptionEnded(sub: 3, code: uint8(ord(ecNotAuthorised)))),
    toMessage(
      LcnCarrierAsyncDone(
        call: 2, value: Opt.some(@[0xA0'u8]), failure: Opt.some(failure())
      )
    ),
    # Lane 2 (part 4b-3.2): the host's loop events.
    toMessage(LcnCarrierIoHello(conn: 7, frame: @[0xA0'u8])),
    toMessage(LcnCarrierIoEstablished(conn: 7)),
    toMessage(
      LcnCarrierIoDispatch(conn: 7, request: 1, `method`: "read", introspection: true)
    ),
    toMessage(LcnCarrierIoStop(conn: 7, request: 1)),
    toMessage(LcnCarrierIoClosed(conn: 7)),
    toMessage(LcnCarrierIoSubscribe(conn: 7, sub: 2, event: "meter.changed_event")),
    toMessage(LcnCarrierIoUnsubscribe(conn: 7, sub: 2)),
    toMessage(
      LcnCarrierIoPublishFailed(conn: 7, event: "meter.changed_event", message: "")
    ),
    toMessage(LcnCarrierIoPublishResult(conn: 7, tag: 3, request: 1)),
    toMessage(
      LcnCarrierIoPublishResult(
        conn: 7,
        tag: 3,
        request: 1,
        failure: Opt.some(LcnCarrierPublishFailure(error: 1, code: 3, message: "x")),
      )
    ),
    toMessage(LcnCarrierIoLocalFailure(conn: 7, code: 3, message: "")),
    # The provider's calls: commitments and steps only, no payloads.
    toMessage(LcnCarrierCallEnded(call: 1, succeeded: false)),
    toMessage(
      LcnCarrierCallEnded(
        call: 2,
        succeeded: true,
        request: Opt.some(LcnCarrierCommitment(subtree_root: root, value_root: root)),
        response: Opt.some(LcnCarrierCommitment(subtree_root: root, value_root: root)),
      )
    ),
    toMessage(LcnCarrierScopedCheck(id: 23, call: 1, event: @[0x65'u8])),
    toMessage(LcnCarrierScopedAdmit(id: 24, call: 1, event: "meter.changed_event")),
    toMessage(LcnCarrierScopedDone(id: 25, call: 1, tag: 3, abandon: true)),
    # The Runtime's orders.
    toMessage(LcnCarrierIoAdmitEstablished(conn: 7, response: @[], contract: root)),
    toMessage(
      LcnCarrierIoAdmitEstablished(
        conn: 7,
        response: @[0xA0'u8],
        contract: root,
        methods: Opt.some(@[root]),
        publish_events: Opt.some(newSeq[seq[byte]]()),
        subscribe_events: Opt.some(@[root, root]),
        ends_in: Opt.some(60_000_000_000'u64),
      )
    ),
    toMessage(LcnCarrierIoAdmitFailed(conn: 7, code: 4, peer: true)),
    toMessage(LcnCarrierIoAdmitUnavailable(conn: 7)),
    toMessage(
      LcnCarrierIoRespond(conn: 7, request: 1, failure: failure(), work_ended: false)
    ),
    toMessage(LcnCarrierIoClose(conn: 7)),
    toMessage(LcnCarrierIoTerminate(conn: 7, code: 4, phase: 0)),
    toMessage(LcnCarrierIoTerminate(conn: 7, code: 8, phase: 2)),
    toMessage(LcnCarrierIoWorkEnded(conn: 7, request: 1)),
    toMessage(LcnCarrierIoEndSubscription(conn: 7, sub: 2)),
    toMessage(LcnCarrierIoSubscriptionResult(conn: 7, sub: 2)),
    toMessage(
      LcnCarrierIoSubscriptionResult(conn: 7, sub: 2, failure: Opt.some(failure()))
    ),
    toMessage(LcnCarrierIoStopServing()),
    toMessage(
      LcnCarrierAdmitVerdict(
        conn: 7, request: 1, contract: root, failure: Opt.some(failure())
      )
    ),
    toMessage(
      LcnCarrierAdmitVerdict(
        conn: 7,
        request: 1,
        contract: root,
        call: Opt.some(1'u64),
        consumer: Opt.some("client"),
        retain_request: true,
        retain_response: true,
      )
    ),
    toMessage(LcnCarrierCallCancel(call: 1)),
    toMessage(LcnCarrierScopedResult(id: 23)),
    toMessage(
      LcnCarrierScopedResult(
        id: 24,
        failure: Opt.some(failure()),
        ready: Opt.some(true),
        tag: Opt.some(3'u64),
      )
    ),
  ]

proc bodyOf(m: LcnCarrierMessage): seq[byte] =
  let f = frameOf(m).tryGet
  f[4 ..^ 1]

suite "run.carrier: messages and frames (plan §2.4) [IMPL]":
  test "[IMPL] every message kind round-trips byte for byte":
    var kinds: set[LcnCarrierMessageKind]
    for m in samples():
      kinds.incl(m.kind)
      let body = bodyOf(m)
      let back = decodeMessage(body)
      check back.isOk
      if back.isOk:
        check back.get.kind == m.kind
        check bodyOf(back.get) == body
    check kinds == {low(LcnCarrierMessageKind) .. high(LcnCarrierMessageKind)}

  test "[IMPL] a body that is not exactly one message is refused":
    let body = bodyOf(toMessage(LcnCarrierRelease(id: 1)))
    check decodeMessage(body & @[0x00'u8]).isErr # a second item
    check decodeMessage(body[0 ..^ 2]).isErr # cut short
    check decodeMessage(@[]).isErr
    check decodeMessage(encodeCbor(cborMap((cbor("kind"), cbor("restart"))))).isErr
    var extra = decodeCbor(body).tryGet
    extra.entries.add((cbor("consumer"), cbor("someone-else")))
    check decodeMessage(encodeCbor(extra)).isErr # a release names no consumer
    # A required field missing, and a value outside its bound.
    check decodeMessage(encodeCbor(cborMap((cbor("kind"), cbor("release"))))).isErr
    let fatal = toMessage(LcnCarrierFatal(message: newString(513)))
    check frameOf(fatal).isErr

  test "[IMPL] frames split at any byte are reassembled; one over the limit fails the reader":
    var stream: seq[byte]
    let all = samples()
    for m in all:
      stream.add(frameOf(m).tryGet)
    var r = newCarrierReader()
    var got: seq[seq[byte]]
    for b in stream:
      let more = r.feed([b])
      check more.isOk
      if more.isOk:
        got.add(more.get)
    check got == all.mapIt(bodyOf(it))
    check r.buffered == 0
    var over = newCarrierReader()
    let prefix = prefixOf(int(CarrierFrameLimit) + 1)
    let refused = over.feed(prefix)
    check refused.isErr
    if refused.isErr:
      check refused.error.declared == uint64(CarrierFrameLimit) + 1
    check over.failed

  test "[IMPL] the largest frame fits an 8 MiB call surface or configuration (LOADER l.441)":
    let big = toMessage(
      LcnCarrierInitialized(
        id: 1, call_surface: Opt.some(newSeq[byte](8 * 1024 * 1024))
      )
    )
    check frameOf(big).isOk
    let tooBig = toMessage(
      LcnCarrierApply(id: 1, configuration: newSeq[byte](int(CarrierFrameLimit)))
    )
    check frameOf(tooBig).isErr

  test "[IMPL] a failure keeps code, message and detail; an out-of-range code reads as MODULE_ERROR":
    let f = failure()
    let a = toAbi(f)
    check a.code == ecModule and a.message == f.message and a.detail == f.detail
    check a.reason == "an invalid status"
    check toCarrier(a) == f
    check toAbi(LcnCarrierFailure(code: 0)).code == ecModule
    check toAbi(LcnCarrierFailure(code: 250)).code == ecModule
    check toInvocation(LcnCarrierFailure(code: uint8(ord(ecNotReady)))).code ==
      ecNotReady

# Lane 2 (part 4b-3.2) ----------------------------------------------------------------------

const
  Index = 3'u64 ## the host's index
  HostConn = AcceptedConnBase + 7 ## the host loop's number for a connection

proc crossed(m: Opt[LcnCarrierMessage]): LcnCarrierMessage =
  ## `m` through a frame and back.
  doAssert m.isSome
  decodeMessage(frameOf(m.get).tryGet[4 ..^ 1]).tryGet

proc roundTrip(ev: IoEvent): IoEvent =
  ## Host to Runtime: the event the Runtime takes from the host's message.
  toEvent(crossed(toMessage(ev)), Index).tryGet.get

proc roundTrip(cmd: IoCommand): IoCommand =
  ## Runtime to host: the command the host's loop takes.
  toCommand(crossed(toMessage(cmd))).tryGet.get

suite "run.carrier: a hosted provider's loop over lane 2 (G273) [IMPL]":
  let runtimeConn = hostedConn(Index, HostConn).get

  test "[IMPL-DECISION G273] the host's numbers and the Runtime's are apart and map one to one":
    check runtimeConn.isHostedConn
    check not HostConn.isHostedConn
    check not ConnId(5).isHostedConn # a caller-side connection of the Runtime
    check hostOfConn(runtimeConn) == Index
    check hostConnOf(runtimeConn) == HostConn
    check hostedEndpoint(Index).isHostedEndpoint
    check hostOfEndpoint(hostedEndpoint(Index)) == Index
    check not EndpointId(1).isHostedEndpoint
    check hostedConn(Index, ConnId(5)).isNone # no loop accepts with that number
    check hostedConn(MaxHostIndex + 1, HostConn).isNone
    check hostedConn(MaxHostIndex, HostConn).get != hostedConn(0, HostConn).get
    check IoCommand(conn: runtimeConn, kind: IoCommandKind.cmdClose).isHostedCommand
    check not IoCommand(conn: HostConn, kind: IoCommandKind.cmdClose).isHostedCommand
    check IoCommand(
      kind: IoCommandKind.cmdStopServing, stopEndpoint: hostedEndpoint(Index)
    ).isHostedCommand

  test "[IMPL-DECISION G273] every callee event of the host's loop reaches the Runtime as the same event, in its numbers":
    let ep = hostedEndpoint(Index)
    block:
      let ev = roundTrip(
        IoEvent(
          conn: HostConn,
          kind: IoEventKind.evHello,
          helloEndpoint: HostEndpoint,
          frame: @[1'u8, 2],
        )
      )
      check ev.conn == runtimeConn and ev.helloEndpoint == ep and ev.frame == @[1'u8, 2]
    block:
      let ev = roundTrip(
        IoEvent(conn: HostConn, kind: IoEventKind.evEstablished, endpoint: HostEndpoint)
      )
      check ev.conn == runtimeConn and ev.endpoint == ep
    block:
      let ev = roundTrip(
        IoEvent(
          conn: HostConn,
          kind: IoEventKind.evDispatch,
          requestId: 9,
          methodName: "read",
          params: @[0xA0'u8],
          introspection: false,
        )
      )
      check ev.conn == runtimeConn and ev.requestId == 9 and ev.methodName == "read"
      # [RUN-0815] The params stay in the host.
      check ev.params.len == 0 and not ev.introspection
    block:
      let ev = roundTrip(IoEvent(conn: HostConn, kind: IoEventKind.evStop, stopId: 9))
      check ev.conn == runtimeConn and ev.stopId == 9
    block:
      let ev = roundTrip(
        IoEvent(conn: HostConn, kind: IoEventKind.evClosed, cause: ccPeerError)
      )
      check ev.conn == runtimeConn and ev.kind == IoEventKind.evClosed
    block:
      let ev = roundTrip(
        IoEvent(
          conn: HostConn,
          kind: IoEventKind.evSubscribe,
          subscribeId: 4,
          subscribeEvent: "meter.changed_event",
        )
      )
      check ev.subscribeId == 4 and ev.subscribeEvent == "meter.changed_event"
    block:
      let ev = roundTrip(
        IoEvent(conn: HostConn, kind: IoEventKind.evUnsubscribe, subscribeId: 4)
      )
      check ev.kind == IoEventKind.evUnsubscribe and ev.subscribeId == 4
    block:
      let ev = roundTrip(
        IoEvent(
          conn: HostConn,
          kind: IoEventKind.evPublishFailed,
          pubFailEvent: "e",
          pubFailMsg: "too large",
        )
      )
      check ev.pubFailEvent == "e" and ev.pubFailMsg == "too large"
    block:
      let f = PublishFailure(kind: high(PublishErrorKind), code: ecNotReady, msg: "m")
      let ev = roundTrip(
        IoEvent(
          conn: HostConn,
          kind: IoEventKind.evPublishResult,
          pubResultTag: 5,
          pubResultRequest: 9,
          pubResultFailure: Opt.some(f),
        )
      )
      check ev.pubResultTag == 5 and ev.pubResultRequest == 9
      check ev.pubResultFailure == Opt.some(f)
    block:
      let ev = roundTrip(
        IoEvent(
          conn: HostConn,
          kind: IoEventKind.evLocalFailure,
          localCode: ecNotReady,
          localMsg: "stopped",
        )
      )
      check ev.localCode == ecNotReady and ev.localMsg == "stopped"
    # The caller side's events, the serve outcome (lane 0's `init_failed`
    # reports a listener the host cannot serve) and the loop's own end stay in
    # the host.
    for k in [
      IoEventKind.evConnected, IoEventKind.evConnectFailed, IoEventKind.evResponse,
      IoEventKind.evListening, IoEventKind.evServeFailed, IoEventKind.evStopped,
      IoEventKind.evEvent, IoEventKind.evSubscription,
    ]:
      check toMessage(IoEvent(kind: k)).isNone
    # A connection number no loop gives breaks the protocol.
    check toEvent(toMessage(LcnCarrierIoClosed(conn: 5)), Index).isErr

  test "[IMPL-DECISION G273] every order for a hosted connection reaches the host's loop as the same command, in its numbers":
    var contract: Digest
    contract[0] = 1
    block:
      let binding = RouteBinding(
        route: "a route the host never sees",
        contract: contract,
        access: RouteAccess(methods: Opt.some(@[contract])),
      )
      let cmd = roundTrip(
        IoCommand(
          conn: runtimeConn,
          kind: IoCommandKind.cmdAdmit,
          verdict: AdmitVerdict(
            kind: avEstablished,
            response: @[0xA0'u8],
            binding: binding,
            endsIn: Opt.some(1_000'i64),
          ),
        )
      )
      check cmd.conn == HostConn and cmd.kind == IoCommandKind.cmdAdmit
      check cmd.verdict.kind == avEstablished and cmd.verdict.response == @[0xA0'u8]
      check cmd.verdict.binding.contract == contract
      check cmd.verdict.binding.access.methods == Opt.some(@[contract])
      check cmd.verdict.binding.route == "" # [RUN-0175] only the contract and access
      check cmd.verdict.endsIn == Opt.some(1_000'i64)
    block:
      let cmd = roundTrip(
        IoCommand(
          conn: runtimeConn,
          kind: IoCommandKind.cmdAdmit,
          verdict: AdmitVerdict(kind: avFailed, code: ecNotAuthorised, peer: true),
        )
      )
      check cmd.verdict.kind == avFailed and cmd.verdict.code == ecNotAuthorised
      check cmd.verdict.peer
    block:
      let cmd = roundTrip(
        IoCommand(
          conn: runtimeConn,
          kind: IoCommandKind.cmdAdmit,
          verdict: AdmitVerdict(kind: avUnavailable),
        )
      )
      check cmd.verdict.kind == avUnavailable
    block:
      let failed = roundTrip(
        IoCommand(
          conn: runtimeConn,
          kind: IoCommandKind.cmdRespond,
          requestId: 9,
          outcome: CallOutcome(
            ok: false,
            failure: InvocationFailure(code: ecNotAuthorised, message: Opt.some("no")),
          ),
          workEnded: true,
        )
      )
      check failed.conn == HostConn and failed.requestId == 9 and failed.workEnded
      check not failed.outcome.ok and failed.outcome.failure.code == ecNotAuthorised
    for k in [IoCommandKind.cmdClose, IoCommandKind.cmdTerminate]:
      let cmd = roundTrip(IoCommand(conn: runtimeConn, kind: k))
      check cmd.kind == k and cmd.conn == HostConn
    # [TXT-0124] The termination code and phase cross as they are.
    for code in [ecNotAuthorised, ecNotReady]:
      for phase in TermPhase:
        let cmd = roundTrip(
          IoCommand(
            conn: runtimeConn,
            kind: IoCommandKind.cmdTerminate,
            termCode: code,
            termPhase: phase,
          )
        )
        check cmd.termCode == code and cmd.termPhase == phase
    block:
      let cmd = roundTrip(
        IoCommand(conn: runtimeConn, kind: IoCommandKind.cmdEndSubscription, subId: 6)
      )
      check cmd.kind == IoCommandKind.cmdEndSubscription
      check cmd.conn == HostConn and cmd.subId == 6
    # Any other code or phase breaks the carrier.
    for (code, phase) in [(0'u64, 0'u64), (3, 0), (9, 0), (4, 3), (8, 255)]:
      check toCommand(
        decodeMessage(
          encodeCbor(
            cborMap(
              (cbor("kind"), cbor("io_terminate")),
              (cbor("conn"), cbor(7'u64)),
              (cbor("code"), cbor(code)),
              (cbor("phase"), cbor(phase)),
            )
          )
        ).tryGet
      ).isErr
    block:
      let cmd = roundTrip(
        IoCommand(conn: runtimeConn, kind: IoCommandKind.cmdWorkEnded, endedId: 9)
      )
      check cmd.conn == HostConn and cmd.endedId == 9
    block:
      let cmd = roundTrip(
        IoCommand(
          conn: runtimeConn,
          kind: IoCommandKind.cmdSubscriptionResult,
          subId: 4,
          subFailure: Opt.some(InvocationFailure(code: ecNotAuthorised)),
        )
      )
      check cmd.subId == 4 and cmd.subFailure.get.code == ecNotAuthorised
    block:
      let cmd = roundTrip(
        IoCommand(
          kind: IoCommandKind.cmdStopServing, stopEndpoint: hostedEndpoint(Index)
        )
      )
      check cmd.kind == IoCommandKind.cmdStopServing and cmd.stopEndpoint == HostEndpoint
    # The caller side's commands never go to a host.
    for k in [
      IoCommandKind.cmdConnect, IoCommandKind.cmdCall, IoCommandKind.cmdCancel,
      IoCommandKind.cmdSubscribe, IoCommandKind.cmdRelease,
    ]:
      check toMessage(IoCommand(conn: runtimeConn, kind: k)).isNone
    # [RUN-0815; G273 interim (K38)] Nothing that carries a payload or commits
    # a success goes to a host: its loop commits those itself.
    check toMessage(
      IoCommand(
        conn: runtimeConn,
        kind: IoCommandKind.cmdRespond,
        requestId: 9,
        outcome: CallOutcome(ok: true, result: @[0xA0'u8]),
      )
    ).isNone
    for k in [
      IoCommandKind.cmdIntrospect, IoCommandKind.cmdPublishConn,
      IoCommandKind.cmdPublishScoped, IoCommandKind.cmdPublish,
    ]:
      check toMessage(IoCommand(conn: runtimeConn, kind: k)).isNone
    # A Response with no failure is not an order (the schema requires one).
    check decodeMessage(
      encodeCbor(
        cborMap(
          (cbor("kind"), cbor("io_respond")),
          (cbor("conn"), cbor(7'u64)),
          (cbor("request"), cbor(1'u64)),
          (cbor("work_ended"), cbor(true)),
        )
      )
    ).isErr

  test "[IMPL] the transport configuration reaches the host as it is; words that are not one are refused":
    let c = defaultTransportConfig()
    let back = transportOf(transportWords(c))
    check back.isOk
    if back.isOk:
      check transportWords(back.get) == transportWords(c)
    check transportOf(transportWords(c)[0 ..^ 2]).isErr
    check transportOf(newSeq[uint64]()).isErr
