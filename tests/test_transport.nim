## TRANSPORT (Tier 3, sans-I/O): the envelope codec, framing and the sender's
## size check, deterministic CBOR and payload depth, the Hello exchange and route
## tickets, correlation, requests, cancellation, multiplexing, subscriptions,
## route termination, per-connection limits and protocol evolution.

import std/[importutils, sequtils, strutils]
import unittest2
import ../src/logos_core/[cbor, hash, commitment, transport]
import ../src/logos_core/iface/[accept, surface, outcome, payload]
import ../src/logos_core/crypto/blake3
import ../src/logos_core/base/hex
import ./support/specdata

const Second = 1_000_000_000'i64

type CallOutcome = outcome.Outcome

let
  storage = acceptContractSet(mirror("IFC/1.8.module.cddl")).get
  root = storage.primary.root
  sensor = acceptContractSet(
    mirror("IFC/3.9.2.module.cddl"),
    [mirror("IFC/3.9.2.interface.cddl")],
    [mirror("IFC/3.9.2.supporting.cddl")],
  ).get
  sensorIface = sensor.interfaces[0].root
  storageBoundary = boundary(storage, root).get

# Helpers -----------------------------------------------------------------------------

proc params(cid = "bafy"): CborValue =
  cborMap((cbor("cid"), cbor(cid)))

proc subtreeOf(declaration: string): Digest =
  let m = storage.primary.model
  declarationRoot(m, m.find(declaration).get)

proc kindMap(kind: uint64, fields: varargs[(string, CborValue)]): CborValue =
  var e: seq[CborEntry] = @[(cbor(0'u64), cbor(kind))]
  for (k, v) in fields:
    e.add((cbor(k), v))
  cborMap(e)

proc without(v: CborValue, key: string): CborValue =
  cborMap(v.entries.filterIt(not (it.key.kind == ckText and it.key.text == key)))

proc with(v: CborValue, key: CborValue, x: CborValue): CborValue =
  var e = v.entries.filterIt(it.key != key)
  e.add((key, x))
  cborMap(e)

proc with(v: CborValue, key: string, x: CborValue): CborValue =
  v.with(cbor(key), x)

proc wire(v: CborValue): seq[byte] =
  encodeCbor(v)

proc envelopeError(v: CborValue): EnvelopeError =
  let r = decodeMessage(wire(v))
  doAssert r.isErr, "accepted: " & toDiag(v)
  r.error

proc commitmentOf(declaration: string, v: CborValue): PayloadCommitment =
  let r = storage.schemaSet.normalize(0, declaration, v).get
  PayloadCommitment(subtreeRoot: r.subtreeRoot, valueRoot: valueRoot(r).get)

proc ticketBytes(seed: byte): seq[byte] =
  toSeq(0'u8 ..< 32'u8).mapIt(it + seed)

proc samples(): seq[Message] =
  ## One valid message of every form.
  let detail = invalidParamsDetail(iprSchemaMismatch, Opt.some(@[cbor("cid")]))
  @[
    Message(
      kind: mkHello,
      hello: Hello(module: "storage_module", token: ticketBytes(1), schema: root),
    ),
    Message(
      kind: mkRequest,
      request: Request(
        id: 1,
        methodName: "exists",
        params: params(),
        commitment: commitmentOf("storage.exists_request", params()),
      ),
    ),
    Message(
      kind: mkResponse,
      response: Response(
        id: 1,
        ok: true,
        resultMap: cborMap((cbor("exists"), cbor(true))),
        commitment:
          commitmentOf("storage.exists_response", cborMap((cbor("exists"), cbor(true)))),
      ),
    ),
    Message(
      kind: mkResponse,
      response: Response(
        id: 2,
        ok: false,
        failure: InvocationFailure(
          code: ecInvalidParams, message: Opt.some("no"), detail: Opt.some(detail)
        ),
      ),
    ),
    Message(
      kind: mkSubscribe, subscribe: Subscribe(id: 3, event: "storage.started_event")
    ),
    Message(kind: mkUnsubscribe, unsubscribe: Unsubscribe(id: 3)),
    Message(
      kind: mkEvent,
      event: Event(
        sub: 3,
        event: "storage.started_event",
        data: cborMap(),
        commitment: commitmentOf("storage.started_event", cborMap()),
      ),
    ),
    Message(
      kind: mkProtocolError,
      protocolError: InvocationFailure(code: ecNotAuthorised, message: Opt.some("x")),
    ),
    Message(kind: mkCancel, cancel: Cancel(id: 1)),
    Message(
      kind: mkSubscriptionResult,
      subscriptionResult: SubscriptionResult(id: 3, operation: mkSubscribe),
    ),
    Message(
      kind: mkSubscriptionResult,
      subscriptionResult: SubscriptionResult(
        id: 3,
        operation: mkUnsubscribe,
        failure: Opt.some(InvocationFailure(code: ecInvalidParams)),
      ),
    ),
  ]

proc closeCode(acts: seq[CalleeAction]): Opt[ErrorCode] =
  for a in acts:
    if a.kind == caClose and a.close.send.isSome:
      return Opt.some(decodeMessage(a.close.send.get).get.protocolError.code)
  Opt.none(ErrorCode)

proc closeCode(evs: seq[CallerEvent]): Opt[ErrorCode] =
  for e in evs:
    if e.kind == ceClose and e.close.send.isSome:
      return Opt.some(decodeMessage(e.close.send.get).get.protocolError.code)
  Opt.none(ErrorCode)

proc sent(acts: seq[CalleeAction]): seq[Message] =
  var ms: seq[Message]
  for a in acts:
    if a.kind == caSend:
      ms.add(decodeMessage(a.bytes).get)
  ms

proc dispatched(acts: seq[CalleeAction]): seq[Request] =
  var rs: seq[Request]
  for a in acts:
    if a.kind == caDispatch:
      rs.add(a.request)
  rs

proc pair(b = storageBoundary): (CallerConn, CalleeConn) =
  (callerConn(b), calleeConn(b))

proc rawRequest(
    id: uint64, methodName: string, p: CborValue, c: PayloadCommitment
): seq[byte] =
  ## As a peer may send it: envelope fields well-typed, payload unchecked.
  wire(
    toCbor(
      Message(
        kind: mkRequest,
        request: Request(id: id, methodName: methodName, params: p, commitment: c),
      )
    )
  )

proc rawResponse(id: uint64, value: CborValue, c: PayloadCommitment): seq[byte] =
  wire(
    toCbor(
      Message(
        kind: mkResponse,
        response: Response(id: id, ok: true, resultMap: value, commitment: c),
      )
    )
  )

proc rawEvent(
    sub: uint64, event: string, data: CborValue, c: PayloadCommitment
): seq[byte] =
  wire(
    toCbor(
      Message(
        kind: mkEvent, event: Event(sub: sub, event: event, data: data, commitment: c)
      )
    )
  )

proc subscribeMsg(id: uint64, event: string): seq[byte] =
  encodeMessage(Message(kind: mkSubscribe, subscribe: Subscribe(id: id, event: event))).get

proc unsubscribeMsg(id: uint64): seq[byte] =
  encodeMessage(Message(kind: mkUnsubscribe, unsubscribe: Unsubscribe(id: id))).get

proc protocolErrorMsg(code: ErrorCode): seq[byte] =
  encodeMessage(
    Message(kind: mkProtocolError, protocolError: InvocationFailure(code: code))
  ).get

proc nest(v: CborValue, levels: int): CborValue =
  ## `v` inside `levels` arrays.
  var x = v
  for _ in 0 ..< levels:
    x = cborArray(x)
  x

proc smallPeer(peerLimit: uint32): TransportLimits =
  ## Test only: a peer frame maximum below the 16 MiB floor, which
  ## `transportLimits` refuses, so the oversize paths run on small bodies.
  privateAccess(TransportLimits)
  var l = defaultLimits()
  l.peerFrameLimit = peerLimit
  l

proc closeMessage(acts: seq[CalleeAction]): Opt[InvocationFailure] =
  for a in acts:
    if a.kind == caClose and a.close.send.isSome:
      return Opt.some(decodeMessage(a.close.send.get).get.protocolError)
  Opt.none(InvocationFailure)

proc space(): CallOutcome =
  CallOutcome(
    ok: true,
    response: cborMap(
      (
        cbor("info"),
        cborMap(
          (cbor("quota"), cbor(10'u64)),
          (cbor("used"), cbor(1'u64)),
          (cbor("available"), cbor(9'u64)),
        ),
      )
    ),
  )

proc active(caller: var CallerConn, callee: var CalleeConn, id: uint64, event: string) =
  ## Subscription `id` to `event`, activated on both sides.
  discard callee.receive(caller.subscribe(id, event).get)
  discard caller.receive(callee.subscriptionResult(id).get)

proc requestFor(id: uint64, cid = "bafy"): seq[byte] =
  rawRequest(
    id, "exists", params(cid), commitmentOf("storage.exists_request", params(cid))
  )

proc okExists(): CallOutcome =
  CallOutcome(ok: true, response: cborMap((cbor("exists"), cbor(true))))

# Ticket and Hello fixtures ---------------------------------------------------------------

proc routeBinding(
    contract = root,
    provider = "storage_module",
    endpoint = "ep-1",
    runtime = Opt.none(string),
    consumer = "app",
): RouteBinding =
  RouteBinding(
    consumer: consumer,
    sourceRuntime: runtime,
    provider: provider,
    contract: contract,
    endpoint: endpoint,
    route: "route-1",
  )

let endpoint =
  CalleeEndpoint(endpoint: "ep-1", provider: "storage_module", contracts: @[root])

proc helloMap(
    module = cbor("storage_module"),
    token = cbor(ticketBytes(1)),
    schema = schemaCommitment(root),
): CborValue =
  kindMap(0, ("module", module), ("token", token), ("schema", schema))

proc helloWith(t: openArray[byte], schema = schemaCommitment(root)): seq[byte] =
  wire(helloMap(token = cbor(@t), schema = schema))

# Suites --------------------------------------------------------------------------------

suite "trn.envelope: message kinds and fields (TRANSPORT §1, §1.1, §1.3)":
  test "[TRN-0016] [TRN-0017] [TRN-0018] [TRN-0019] [TRN-0020] [TRN-0021] [TRN-0022] [TRN-0023] [TRN-0024] [TRN-0025] [TRN-0045] the kind registry and the message union come from the mirrored CDDL":
    let s = envelopeSchema()
    let kinds = s.rule("logos.transport.message-kind").get
    for n in 0'i64 .. 8:
      check s.matches(kinds, cbor(n))
    for n in [-1'i64, 9, 255]:
      check not s.matches(kinds, cbor(n))
    for k in MessageKind:
      let arms = messageArms(k)
      check arms.len in 1 .. 2
      for a in arms:
        check s.intValue(a.member(cbor(0'u64)).get.typ) == Opt.some(int64(k.ord))
    check messageArms(mkResponse).len == 2
    check messageArms(mkSubscriptionResult).len == 2
    check KindRule[mkProtocolError] == "logos.transport.protocol-error"

  test "[TRN-0008] [TRN-0009] [TRN-0010] [TRN-0011] [TRN-0012] [TRN-0013] [TRN-0014] [TRN-0015] the §1.1 primitive types and their bounds":
    let s = envelopeSchema()
    proc ok(name: string, v: CborValue): bool =
      s.matches(s.rule("logos.transport." & name).get, v)

    check ok("module-name", cbor("a".repeat(64)))
    check not ok("module-name", cbor(""))
    check not ok("module-name", cbor("a".repeat(65)))
    check ok("method-name", cbor("m".repeat(128)))
    check not ok("method-name", cbor("m".repeat(129)))
    check ok("event-name", cbor("storage.started_event"))
    check not ok("event-name", cbor("e".repeat(129)))
    check ok("call-id", cbor(high(uint64)))
    check not ok("call-id", cbor(-1'i64))
    check ok("subscription-id", cbor(0'u64))
    check not ok("subscription-id", cbor("1"))
    check ok("authorization-material", cbor(newSeq[byte]()))
    check not ok("authorization-material", cbor(""))
    for name in ["schema-subtree-root", "value-root"]:
      check ok(name, cbor(newSeq[byte](32)))
      check not ok(name, cbor(newSeq[byte](31)))
      check not ok(name, cbor(newSeq[byte](33)))

  test "[TRN-0029] [TRN-0030] [TRN-0031] [TRN-0032] [TRN-0033] [TRN-0034] [TRN-0035] [TRN-0036] [TRN-0037] [TRN-0038] [TRN-0039] [TRN-0040] [TRN-0041] [TRN-0042] [TRN-0043] [TRN-0044] every message form round-trips, key 0 first":
    for m in samples():
      let b = encodeMessage(m).get
      # A definite map header, then key 0 (0x00) and the kind.
      check (b[0] shr 5) == 5
      check b[1] == 0x00
      check b[2] == byte(m.kind.ord)
      let back = decodeMessage(b).get
      check back.kind == m.kind
      check encodeCbor(toCbor(back)) == b

  test "[TRN-0006] a message whose first entry is not key 0 is rejected":
    check envelopeError(cborMap((cbor("id"), cbor(7'u64)))).kind == eeFirstKey
    check envelopeError(cborMap((cbor(1'u64), cbor(7'u64)), (cbor("id"), cbor(7'u64)))).kind ==
      eeFirstKey
    check envelopeError(cborMap()).kind == eeFirstKey
    check envelopeError(cborArray(cbor(0'u64), cbor(7'u64))).kind == eeNotMap
    check envelopeError(cbor(7'u64)).kind == eeNotMap

  test "[TRN-0005] the kind is readable from the map header and the first entry":
    for m in samples():
      let b = encodeMessage(m).get
      check peekKind(b) == Opt.some(uint64(m.kind.ord))
    check peekKind(wire(cborMap((cbor("id"), cbor(7'u64))))).isNone
    check peekKind(wire(cbor("x"))).isNone
    check peekKind(@[0xa1'u8]).isNone

  test "[TRN-0028] [TRN-0251] a field the kind does not define is rejected":
    for m in samples():
      let v = toCbor(m)
      let e = envelopeError(v.with("extra", cbor(1'u64)))
      check e.kind == eeUnknownField
      check e.field == "extra"
      check envelopeError(v.with(cbor(1'u64), cbor(1'u64))).kind == eeUnknownField
    # Fields of another kind are unknown too.
    let cancel = kindMap(7, ("id", cbor(1'u64)), ("method", cbor("exists")))
    check envelopeError(cancel).field == "method"

  test "[TRN-0201] [TRN-0251] an unknown or unallocated kind is rejected":
    for k in [cbor(9'u64), cbor(255'u64), cbor(-1'i64), cbor("hello"), cbor(true)]:
      check envelopeError(cborMap((cbor(0'u64), k), (cbor("id"), cbor(1'u64)))).kind ==
        eeUnknownKind

  test "[TRN-0062] [TRN-0202] required fields and field types are checked in CDDL order":
    for m in samples():
      let v = toCbor(m)
      if messageArms(m.kind).len > 1:
        continue
      for (k, _) in v.entries:
        if k.kind != ckText:
          continue
        let optional = messageArms(m.kind)[0].member(k).get.optional
        if not optional:
          let e = envelopeError(v.without(k.text))
          check e.kind == eeField
          check e.field == k.text
        let e = envelopeError(v.with(k.text, cborArray()))
        check e.kind == eeField
        check e.field == k.text
    # Hello fields fail in the order module, token, schema.
    let e = envelopeError(helloMap(token = cbor(1'u64), schema = cbor(2'u64)))
    check e.field == "token"
    check envelopeError(helloMap(module = cbor(""), token = cbor(1'u64))).field ==
      "module"

  test "[TRN-0046] [TRN-0087] [TRN-0102] error codes are nonzero and allocated":
    let zero = InvocationFailure(code: ecOk)
    for m in [
      Message(kind: mkProtocolError, protocolError: zero),
      Message(kind: mkResponse, response: Response(id: 1, ok: false, failure: zero)),
      Message(
        kind: mkSubscriptionResult,
        subscriptionResult:
          SubscriptionResult(id: 1, operation: mkSubscribe, failure: Opt.some(zero)),
      ),
    ]:
      check encodeMessage(m).isErr
      check envelopeError(toCbor(m)).kind == eeRule
    let unallocated = kindMap(6, ("code", cbor(10'u64)))
    check envelopeError(unallocated).kind == eeField

  test "[TRN-0047] [TRN-0103] detail is checked as INTERFACE §5.1 requires":
    let good = invalidParamsDetail(iprMalformedCbor)
    proc pe(code: uint64, detail: seq[byte]): CborValue =
      kindMap(6, ("code", cbor(code)), ("detail", cbor(detail)))

    check decodeMessage(wire(pe(2, good))).isOk
    # Detail is only for INVALID_PARAMS.
    check envelopeError(pe(4, good)).kind == eeRule
    # Not a logos.invalid_params_detail, or not deterministic CBOR.
    check envelopeError(pe(2, encodeCbor(cborMap((cbor("x"), cbor(1'u64)))))).kind ==
      eeRule
    check envelopeError(pe(2, @[0x18'u8, 0x01])).kind == eeRule
    # Over 4096 bytes is outside logos.error_detail.
    check envelopeError(pe(2, newSeq[byte](4097))).kind == eeField
    let resp = kindMap(
      2,
      ("id", cbor(1'u64)),
      ("error", cborMap((cbor("code"), cbor(5'u64)), (cbor("detail"), cbor(good)))),
    )
    check envelopeError(resp).kind == eeRule

  test "[TRN-0086] [TRN-0088] a Response has exactly one of result or error, and no commitment with error":
    let ok = toCbor(samples()[2])
    let failed = toCbor(samples()[3])
    let both = ok.with("error", failed.lookup("error").get)
    check envelopeError(both).kind == eeForm
    check envelopeError(failed.with("commitment", ok.lookup("commitment").get)).kind ==
      eeForm
    check envelopeError(ok.without("result").without("commitment")).kind == eeForm

  test "[IFC-0423] envelopes decode and re-encode without any payload schema":
    # A forwarder needs no contract: the payload maps pass through unchanged,
    # whatever schema they would fail (floats aside: they fail the envelope).
    let invalidText = CborValue(kind: ckText, text: "\xff", validUtf8: false)
    let odd = cborMap(
      (cbor("cid"), cborTag(42, cbor(1'u64))),
      (cbor("x"), cborArray(cborNull(), invalidText)),
    )
    let m = toCbor(samples()[1]).with("params", odd)
    let b = wire(m)
    let back = decodeMessage(b).get
    check back.request.params == odd
    check encodeMessage(back).get == b

  test "[TRN-0042] [TRN-0044] message text is at most 512 bytes":
    let pe = toCbor(samples()[7])
    check decodeMessage(wire(pe.with("message", cbor("m".repeat(512))))).isOk
    check envelopeError(pe.with("message", cbor("m".repeat(513)))).kind == eeField

suite "trn.direction: who sends what (TRANSPORT §1.2, §1.4, §2.3)":
  test "[TRN-0062] [TRN-0272] [TRN-0274] the callee closes on caller-bound kinds":
    for m in samples():
      if m.kind notin {mkResponse, mkEvent, mkSubscriptionResult}:
        continue
      var (_, callee) = pair()
      let acts = callee.receive(encodeMessage(m).get)
      check closeCode(acts) == Opt.some(ecInvalidParams)
      check callee.state == csClosed
      check dispatched(acts).len == 0

  test "[TRN-0062] [TRN-0272] [TRN-0274] the caller closes on callee-bound kinds":
    for m in samples():
      if m.kind notin {mkRequest, mkSubscribe, mkUnsubscribe, mkCancel}:
        continue
      var (caller, _) = pair()
      check closeCode(caller.receive(encodeMessage(m).get)) == Opt.some(ecInvalidParams)
      check caller.state == csClosed

  test "[TRN-0275] [TRN-0326] a ProtocolError from the peer closes without a reply; pending calls get TRANSPORT_ERROR":
    var (caller, callee) = pair()
    let pe = encodeMessage(samples()[7]).get
    let acts = callee.receive(pe)
    check acts.len == 1 and acts[0].kind == caClose and acts[0].close.send.isNone
    discard caller.request("exists", params()).get
    let evs = caller.receive(pe)
    check evs[0].kind == ceResponse and evs[0].outcome.failure.code == ecTransport
    check evs[^1].kind == ceClose and evs[^1].close.send.isNone
    # Whatever its code: a NOT_AUTHORISED session error does not change what
    # the outstanding calls get (§8.1).
    var (caller2, _) = pair()
    discard caller2.request("exists", params()).get
    discard caller2.request("space", cborMap()).get
    let evs2 = caller2.receive(protocolErrorMsg(ecNotAuthorised))
    check evs2.filterIt(it.kind == ceResponse).mapIt(it.outcome.failure.code) ==
      @[ecTransport, ecTransport]
    check evs2[^1].close.code == ecNotAuthorised and evs2[^1].close.send.isNone
    check caller2.state == csClosed

  test "[TRN-0062] a closed connection takes no more input":
    var (caller, callee) = pair()
    discard callee.receive(encodeMessage(samples()[0]).get)
    check callee.state == csClosed
    check callee.receive(requestFor(1)).len == 0
    discard caller.receive(encodeMessage(samples()[0]).get)
    check caller.receive(encodeMessage(samples()[2]).get).len == 0
    check caller.request("exists", params()).error.code == ecNotReady

proc prefix(n: uint64): seq[byte] =
  @[byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)]

suite "trn.framing: stream framing (TRANSPORT §2.1, §8.3)":
  test "[TRN-0051] [TRN-0052] a frame is a 4-byte big-endian length and the body":
    check frame([1'u8, 2, 3]).get == @[0'u8, 0, 0, 3, 1, 2, 3]
    check frame(newSeq[byte](0x0102)).get[0 .. 3] == @[0'u8, 0, 1, 2]
    var r = newFrameReader()
    var stream: seq[byte]
    for m in samples():
      stream.add(frame(encodeMessage(m).get).get)
    var bodies: seq[seq[byte]]
    for b in stream:
      bodies.add(r.feed([b]).get)
    check bodies.len == samples().len
    for i, m in samples():
      check decodeMessage(bodies[i]).get.kind == m.kind
    check r.finish.isOk
    # Several frames in one read, and an empty body.
    var r2 = newFrameReader()
    check r2.feed(stream & frame([]).get).get.len == samples().len + 1

  test "[TRN-0053] [TRN-0054] [TRN-0055] [TRN-0199] a length over the limit fails before the body is read or allocated":
    # Crafted prefixes: no body of that size is ever built.
    var r = newFrameReader()
    check r.feed(prefix(MinFrameLimit)).get.len == 0
    check r.buffered == 0
    check r.feed([1'u8, 2, 3]).get.len == 0
    check r.buffered == 3
    var r2 = newFrameReader()
    let e = r2.feed(prefix(MinFrameLimit + 1) & @[1'u8, 2, 3]).error
    check e.kind == feTooLarge and e.declared == uint64(MinFrameLimit + 1)
    check r2.buffered == 0 and r2.failed
    check r2.feed([1'u8]).isErr
    # The largest prefix: refused from its 4 bytes alone.
    var r3 = newFrameReader()
    check r3.feed([0xff'u8, 0xff, 0xff, 0xff]).error.declared == 0xffffffff'u64
    check r3.buffered == 0
    # The connection sends INVALID_PARAMS, then closes; pending calls fail.
    var (caller, callee) = pair()
    check closeCode(callee.frameFailed(e)) == Opt.some(ecInvalidParams)
    check callee.state == csClosed
    discard caller.request("exists", params()).get
    let evs = caller.frameFailed(e)
    check closeCode(evs) == Opt.some(ecInvalidParams)
    check evs[0].outcome.failure.code == ecTransport

  test "[TRN-0260] [TRN-0262] the active maximum is at least the 16 MiB floor the spec pins":
    let pinned = pin("trn-max-frame-floor")
    check pinned == "16 MiB"
    check MinFrameLimit == parseInt(pinned.split(' ')[0]) * 1024 * 1024
    check newFrameReader().limit == uint32(MinFrameLimit)
    check newFrameReader(uint32(MinFrameLimit)).get.limit == uint32(MinFrameLimit)
    for below in [0'u32, 100, uint32(MinFrameLimit - 1)]:
      check newFrameReader(below).isErr
      check transportLimits(frameLimit = below).isErr
      check transportLimits(peerFrameLimit = below).isErr
    # A larger configured maximum accepts what the floor refuses.
    let larger = transportLimits(frameLimit = 2 * MinFrameLimit).get
    var r = larger.frameReader
    check r.limit == uint32(2 * MinFrameLimit)
    check r.feed(prefix(MinFrameLimit + 1)).isOk
    check r.feed([1'u8, 2, 3, 4]).get.len == 0
    check r.buffered == 4
    var r2 = larger.frameReader
    check r2.feed(prefix(2 * MinFrameLimit + 1)).isErr
    # Absent a separately established larger limit, the sender uses 16 MiB.
    check defaultLimits().frameLimit == uint32(MinFrameLimit)
    check defaultLimits().peerFrameLimit == uint32(MinFrameLimit)

  test "[TRN-0261] [TRN-0262] a body is framed only when it fits the peer-supported maximum":
    # The body is the deterministic-CBOR message, envelope and commitments
    # included, the 4-byte prefix excluded.
    check fits(MinFrameLimit)
    check not fits(MinFrameLimit + 1)
    check fits(MinFrameLimit + 1, uint32(2 * MinFrameLimit))
    check not fits(-1)
    check frame(newSeq[byte](101), 100).error.kind == feTooLarge
    check frame(newSeq[byte](101), 100).error.declared == 101
    check frame(newSeq[byte](100), 100).get.len == 104
    for m in samples():
      let b = encodeMessage(m).get
      check encodeMessage(m, peerLimit = uint32(b.len)).get == b
      check encodeMessage(m, peerLimit = uint32(b.len - 1)).error.kind == eeTooLarge

  test "[TRN-0057] the largest message the core interfaces define fits the floor":
    # The logos.schema response is at most 8 MiB (INTERFACE §5.1); with its
    # envelope it stays far below 16 MiB.
    let big = cborMap((cbor("document"), cbor("x".repeat(MaxSchemaResponseBytes))))
    let m = Message(
      kind: mkResponse,
      response: Response(
        id: high(uint64), ok: true, resultMap: big, commitment: PayloadCommitment()
      ),
    )
    check fits(encodeMessage(m).get.len)

  test "a stream that ends inside a frame is truncated":
    var r = newFrameReader()
    check r.feed([0'u8, 0, 0, 5, 1]).get.len == 0
    check r.finish.error.kind == feTruncated

suite "trn.dcbor: deterministic CBOR and validation (TRANSPORT §2.3, §8.3)":
  test "[TRN-0061] [TRN-0200] non-deterministic envelopes are rejected":
    let cases = [
      "a262696407" & "0007", # keys out of order
      "a2001807" & "62696407", # kind 7 not in shortest form
      "a20007" & "62696418" & "07", # id 7 not in shortest form
      "bf0007" & "62696407" & "ff", # indefinite-length map
      "a30007" & "62696407" & "62696408", # duplicate key
    ]
    for h in cases:
      let e = decodeMessage(hexBytes(h)).error
      check e.kind in {eeNonDeterministic, eeMalformed}
    for m in samples():
      let b = encodeMessage(m).get
      check encodeCbor(decodeValue(b).get) == b

  test "[TRN-0198] malformed CBOR is rejected":
    for h in ["", "a2", "a20007626964", "a2000762696407" & "00", "ff"]:
      check decodeMessage(hexBytes(h)).error.kind == eeMalformed

  test "[TRN-0063] [TRN-0064] [TRN-0065] [TRN-0197] a failed envelope is not dispatched; INVALID_PARAMS, then close":
    var (_, callee) = pair()
    let bad = wire(toCbor(samples()[1]).with("extra", cbor(1'u64)))
    let acts = callee.receive(bad)
    check dispatched(acts).len == 0
    check closeCode(acts) == Opt.some(ecInvalidParams)
    check callee.state == csClosed
    check callee.receive(requestFor(5)).len == 0

  test "[TRN-0062] [TRN-0269] [TRN-0270] [TRN-0271] [IFC-0923] payload depth P bounds params, result and data; the message nests P + 1; deeper is INVALID_PARAMS without detail, then close":
    let start = commitmentOf("storage.exists_request", params())
    proc atDepth(d: int): CborValue =
      # The payload map is depth 1; `d - 1` arrays below it reach depth `d`.
      cborMap((cbor("cid"), nest(cbor(1'u64), d - 1)))

    for p in [MinMaxDepth, 300, DefaultMaxDepth]:
      let l = transportLimits(payloadDepth = p).get
      check l.payloadDepth == p
      # params
      let fitsP = rawRequest(0, "exists", atDepth(p), start)
      let over = rawRequest(0, "exists", atDepth(p + 1), start)
      check decodeMessage(fitsP, p).isOk
      check decodeMessage(over, p).error.kind == eeTooDeep
      var callee = calleeConn(storageBoundary, l)
      let acts = callee.receive(over)
      check dispatched(acts).len == 0
      let pe = closeMessage(acts).get
      check pe.code == ecInvalidParams and pe.detail.isNone and pe.message.isNone
      check callee.state == csClosed
      # Within P, the envelope passes; the schema decides (cid is a tstr).
      var callee2 = calleeConn(storageBoundary, l)
      let r = sent(callee2.receive(fitsP))
      check r[0].response.failure.code == ecInvalidParams and callee2.state == csOpen
      # result and data
      check decodeMessage(rawResponse(0, atDepth(p), start), p).isOk
      check decodeMessage(rawResponse(0, atDepth(p + 1), start), p).error.kind ==
        eeTooDeep
      check decodeMessage(rawEvent(0, "storage.started_event", atDepth(p), start), p).isOk
      check decodeMessage(
        rawEvent(0, "storage.started_event", atDepth(p + 1), start), p
      ).error.kind == eeTooDeep
      var caller = callerConn(storageBoundary, limits = l)
      discard caller.request("exists", params()).get
      let evs = caller.receive(rawResponse(0, atDepth(p + 1), start))
      check evs[0].outcome.failure.code == ecTransport
      check closeCode(evs) == Opt.some(ecInvalidParams)
      # The sender refuses a payload deeper than P: nothing is sent.
      var caller2 = callerConn(storageBoundary, limits = l)
      check caller2.request("exists", atDepth(p + 1)).error.code == ecInvalidParams
      check caller2.pendingCalls == 0
      check encodeMessage(
        Message(
          kind: mkRequest,
          request: Request(
            id: 0, methodName: "exists", params: atDepth(p + 1), commitment: start
          ),
        ),
        payloadDepth = p,
      ).error.kind == eeTooDeep
    # P is configurable from 128; the commitment layer's own bound caps it.
    check transportLimits(payloadDepth = MinMaxDepth - 1).isErr
    check transportLimits(payloadDepth = MaxPayloadDepth + 1).isErr
    check defaultLimits().payloadDepth == DefaultMaxDepth
    # Empty containers count; tags and byte-string contents do not.
    let empties = cborMap((cbor("cid"), nest(cborArray(), MinMaxDepth - 1)))
    check decodeMessage(rawRequest(0, "exists", empties, start), MinMaxDepth).error.kind ==
      eeTooDeep
    var tagged = cbor(1'u64)
    for _ in 0 ..< 10:
      tagged = cborTag(1, tagged)
    let t = cborMap((cbor("cid"), nest(tagged, MinMaxDepth - 1)))
    check decodeMessage(rawRequest(0, "exists", t, start), MinMaxDepth).isOk
    check checkPayload(t, MinMaxDepth).isOk
    check checkPayload(atDepth(MinMaxDepth + 1), MinMaxDepth).error.kind == eeTooDeep

  test "[TRN-0062] [TRN-0063] [TRN-0064] [TRN-0065] [IFC-0920] a float anywhere, payloads included, fails the envelope: INVALID_PARAMS, then close":
    let floats = [
      cborFloatBits(fw16, 0x3e00),
      cborFloatBits(fw32, 0x3fc00000'u64),
      cborFloatBits(fw64, 0x3ff8000000000000'u64),
    ]
    let start = PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_request"))
    for x in floats:
      for p in [
        cborMap((cbor("cid"), x)),
        cborMap((cbor("cid"), cbor("a")), (cbor("x"), cborArray(cborTag(1, x)))),
      ]:
        let b = rawRequest(0, "exists", p, start)
        check decodeMessage(b).error.kind == eeNonDeterministic
        var (_, callee) = pair()
        let acts = callee.receive(b)
        check dispatched(acts).len == 0
        check closeCode(acts) == Opt.some(ecInvalidParams)
        check callee.state == csClosed
        # Not a schema mismatch: no correlated response-err.
        check sent(acts).len == 0
      # In result and data: the caller closes; the pending call fails.
      var (caller, _) = pair()
      let (id, _) = caller.request("exists", params()).get
      let evs = caller.receive(rawResponse(id, cborMap((cbor("exists"), x)), start))
      check evs[0].outcome.failure.code == ecTransport
      check closeCode(evs) == Opt.some(ecInvalidParams)
      var (caller2, callee2) = pair()
      active(caller2, callee2, 1, "storage.started_event")
      check closeCode(
        caller2.receive(
          rawEvent(1, "storage.started_event", cborMap((cbor("x"), x)), start)
        )
      ) == Opt.some(ecInvalidParams)
      # In an envelope field.
      check decodeMessage(wire(kindMap(7, ("id", x)))).error.kind == eeNonDeterministic
      # Senders never emit one.
      var (caller3, _) = pair()
      check caller3.request("exists", cborMap((cbor("cid"), x))).error.code ==
        ecInvalidParams
      check caller3.pendingCalls == 0
      check checkPayload(cborMap((cbor("cid"), cborTag(1, x))), MinMaxDepth).error.kind ==
        eeNonDeterministic

  test "[TRN-0203] [IFC-0423] tags, null and invalid UTF-8 inside payloads pass the envelope and fail at the schema":
    let invalidText = CborValue(kind: ckText, text: "\xff", validUtf8: false)
    for x in [invalidText, cborTag(1, cbor(1'u64)), cborNull()]:
      let p = cborMap((cbor("cid"), x))
      let b = rawRequest(
        0,
        "exists",
        p,
        PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_request")),
      )
      check decodeMessage(b).isOk
      var (_, callee) = pair()
      let acts = callee.receive(b)
      check callee.state == csOpen
      let resp = sent(acts)[0].response
      check not resp.ok and resp.failure.code == ecInvalidParams
    # In an envelope field, invalid UTF-8 is a field-type failure.
    let m = toCbor(samples()[1]).with("method", invalidText)
    check envelopeError(m).field == "method"

suite "trn.hello: Hello and route tickets (TRANSPORT §3.1, §3.3, §8.1)":
  test "[TRN-0068] [TRN-0070] [TRN-0071] [TRN-0075] [TRN-0147] [TRN-0164] [TRN-0176] [TRN-0149] [TRN-0175] a Hello with a live ticket establishes the session":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(consumer = "app-7"), 0, 100 * Second).get
    let req = helloRequest("storage_module", t, root).get
    let est = acceptHello(endpoint, store, req, Second).get
    let resp = decodeMessage(est.response).get.hello
    check resp.module == "storage_module"
    check resp.token.len == 0
    check resp.schema == root
    check est.binding.consumer == "app-7"
    check est.binding.contract == root
    check store.len == 0
    let sent = decodeMessage(req).get.hello
    check acceptHelloResponse(sent, est.response).isOk

  test "[TRN-0072] [TRN-0318] a missing or malformed module is INVALID_PARAMS and consumes nothing; another module is NOT_AUTHORISED":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    for module in [cbor(""), cbor("m".repeat(65)), cbor(7'u64)]:
      let f =
        acceptHello(endpoint, store, wire(helloMap(module, cbor(@t))), Second).error
      check f.code == ecInvalidParams and f.reason == hrModule
    let missing = wire(helloMap(token = cbor(@t)).without("module"))
    check acceptHello(endpoint, store, missing, Second).error.code == ecInvalidParams
    check store.validate(t, Second).isOk
    let other = wire(helloMap(cbor("other_module"), cbor(@t)))
    check acceptHello(endpoint, store, other, Second).error.code == ecNotAuthorised
    check store.validate(t, Second).isOk

  test "[TRN-0073] [TRN-0144] [TRN-0155] [TRN-0318] a missing, empty, malformed or unknown token is NOT_AUTHORISED and consumes nothing":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    for token in [
      cbor(newSeq[byte]()),
      cbor(t[0 .. 30]),
      cbor(@t & @[0'u8]),
      cbor(ticketBytes(9)),
      cbor("ticket"),
    ]:
      let f = acceptHello(endpoint, store, wire(helloMap(token = token)), Second).error
      check f.code == ecNotAuthorised
    check acceptHello(endpoint, store, wire(helloMap().without("token")), Second).error.code ==
      ecNotAuthorised
    check store.len == 1
    check store.validate(t, Second).isOk

  test "[TRN-0074] [TRN-0071] [TRN-0254] [TRN-0318] a schema that differs or is malformed is VERSION_MISMATCH, after the token check":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    let other = sensor.primary.root
    check acceptHello(endpoint, store, helloWith(t, schemaCommitment(other)), Second).error.code ==
      ecVersionMismatch
    let profile =
      schemaCommitment(root).with("hash_profile", cbor("logos.hash-profile.other"))
    check acceptHello(endpoint, store, helloWith(t, profile), Second).error.code ==
      ecVersionMismatch
    let otherSuite =
      schemaCommitment(root).with("hash_suite", cbor("logos.hash-suite.sha-256"))
    check acceptHello(endpoint, store, helloWith(t, otherSuite), Second).error.code ==
      ecVersionMismatch
    check acceptHello(endpoint, store, helloWith(t, cbor(1'u64)), Second).error.code ==
      ecVersionMismatch
    check acceptHello(
      endpoint, store, wire(helloMap(token = cbor(@t)).without("schema")), Second
    ).error.code == ecVersionMismatch
    check store.validate(t, Second).isOk
    # The token check comes first: a bad ticket and a bad schema is NOT_AUTHORISED.
    check acceptHello(endpoint, store, helloWith(ticketBytes(9), cbor(1'u64)), Second).error.code ==
      ecNotAuthorised
    # Framing, CBOR, kind and unknown fields come before every field check.
    check acceptHello(
      endpoint, store, wire(helloMap(module = cbor("")).with("x", cbor(1'u64))), Second
    ).error.reason == hrEnvelope

  test "[TRN-0146] [TRN-0145] [TRN-0157] [TRN-0177] [TRN-0079] [TRN-0075] a redeemed ticket never establishes another session":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    check acceptHello(endpoint, store, helloWith(t), Second).isOk
    let again = acceptHello(endpoint, store, helloWith(t), 2 * Second).error
    check again.code == ecNotAuthorised
    # Two connections racing: both validate, one redemption wins.
    let t2 = store.issue(routeBinding(), 0, 100 * Second).get
    check store.validate(t2, Second).isOk
    check store.validate(t2, Second).isOk
    check store.redeem(t2, Second).isOk
    check store.redeem(t2, Second).error == tfUnknown

  test "[TRN-0148] [TRN-0150] [TRN-0152] [TRN-0154] [TRN-0173] [TRN-0174] the ticket binds provider, contract, endpoint, source Runtime and expiry":
    var store: TicketStore[RouteBinding]
    for b in [
      routeBinding(provider = "other_module"),
      routeBinding(endpoint = "ep-2"),
      routeBinding(contract = sensorIface),
      routeBinding(runtime = Opt.some("runtime-b")),
    ]:
      let t = store.issue(b, 0, 100 * Second).get
      let f =
        acceptHello(endpoint, store, helloWith(t, schemaCommitment(b.contract)), Second)
      check f.error.code == ecNotAuthorised
      check store.validate(t, Second).isOk
    # A remote connection from the bound Runtime.
    var remote = endpoint
    remote.sourceRuntime = Opt.some("runtime-a")
    let t =
      store.issue(routeBinding(runtime = Opt.some("runtime-a")), 0, 100 * Second).get
    check acceptHello(remote, store, helloWith(t), Second).isOk
    let t2 =
      store.issue(routeBinding(runtime = Opt.some("runtime-b")), 0, 100 * Second).get
    check acceptHello(remote, store, helloWith(t2), Second).error.code == ecNotAuthorised
    # A local ticket presented on a remote connection.
    let t3 = store.issue(routeBinding(), 0, 100 * Second).get
    check acceptHello(remote, store, helloWith(t3), Second).error.code == ecNotAuthorised
    # An interface contract this provider serves.
    let both = CalleeEndpoint(
      endpoint: "ep-1", provider: "storage_module", contracts: @[root, sensorIface]
    )
    let t4 = store.issue(routeBinding(contract = sensorIface), 0, 100 * Second).get
    check acceptHello(both, store, helloWith(t4, schemaCommitment(sensorIface)), Second).isOk
    # Expired.
    let t5 = store.issue(routeBinding(), 0, 10 * Second).get
    check acceptHello(endpoint, store, helloWith(t5), 10 * Second).error.code ==
      ecNotAuthorised

  test "[TRN-0166] [TRN-0167] [TRN-0171] every NOT_AUTHORISED outcome looks the same and never shows the ticket":
    var store: TicketStore[RouteBinding]
    var failures: seq[HelloFailure]
    let live = store.issue(routeBinding(), 0, 100 * Second).get
    let wrongProvider = store.issue(routeBinding(provider = "x"), 0, 100 * Second).get
    let expired = store.issue(routeBinding(), 0, Second).get
    failures.add(acceptHello(endpoint, store, helloWith(ticketBytes(5)), Second).error)
    failures.add(acceptHello(endpoint, store, helloWith(wrongProvider), Second).error)
    failures.add(acceptHello(endpoint, store, helloWith(expired), 2 * Second).error)
    failures.add(
      acceptHello(endpoint, store, wire(helloMap(cbor("x"), cbor(@live))), Second).error
    )
    for f in failures:
      check f.code == ecNotAuthorised
      check f.msg == NotAuthorisedMessage
      for t in [live, wrongProvider, expired]:
        check toHex(t) notin f.msg.toLowerAscii
    let v = acceptHello(endpoint, store, helloWith(live, cbor(1'u64)), Second).error
    check toHex(live) notin v.msg.toLowerAscii

  test "[TRN-0277] [TRN-0070] the caller checks the module, token and schema of the answer, in that order":
    let sent = Hello(module: "storage_module", token: ticketBytes(1), schema: root)
    proc answer(
        module = "storage_module", token: seq[byte] = @[], schema = root
    ): seq[byte] =
      encodeMessage(
        Message(
          kind: mkHello, hello: Hello(module: module, token: token, schema: schema)
        )
      ).get

    check acceptHelloResponse(sent, answer()).isOk
    check acceptHelloResponse(sent, answer(module = "other")).error.code ==
      ecInvalidParams
    check acceptHelloResponse(sent, answer(schema = sensorIface)).error.code ==
      ecVersionMismatch
    check acceptHelloResponse(
      sent, wire(helloMap(token = cbor(newSeq[byte]()), schema = cbor(1'u64)))
    ).error.code == ecVersionMismatch
    # This profile requires an empty response token: anything else is
    # NOT_AUTHORISED.
    check acceptHelloResponse(sent, answer(token = @[1'u8])).error.code ==
      ecNotAuthorised
    # The first failing check is reported: module, then token, then schema.
    let all = answer(module = "other", token = @[1'u8], schema = sensorIface)
    check acceptHelloResponse(sent, all).error.code == ecInvalidParams
    let tokenAndSchema = answer(token = @[1'u8], schema = sensorIface)
    check acceptHelloResponse(sent, tokenAndSchema).error.code == ecNotAuthorised
    # The callee's ProtocolError is the outcome; nothing is sent back
    # (§2.3; RUNTIME §4.1).
    let refused = protocolErrorMsg(ecVersionMismatch)
    let f = acceptHelloResponse(sent, refused).error
    check f.code == ecVersionMismatch and f.peer and f.reason == hrPeer
    check acceptHelloResponse(sent, encodeMessage(samples()[8]).get).error.code ==
      ecInvalidParams

  test "[TRN-0062] [TRN-0273] [TRN-0274] before the Hello only a Hello or a ProtocolError is accepted; anything else is INVALID_PARAMS":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    let sentHello = Hello(module: "storage_module", token: @t, schema: root)
    for m in samples():
      if m.kind in {mkHello, mkProtocolError}:
        continue
      let b = encodeMessage(m).get
      let f = acceptHello(endpoint, store, b, Second).error
      check f.code == ecInvalidParams and not f.peer and f.reason == hrEnvelope
      let g = acceptHelloResponse(sentHello, b).error
      check g.code == ecInvalidParams and not g.peer
    check store.len == 1
    check store.validate(t, Second).isOk

  test "[TRN-0275] [TRN-0318] a ProtocolError before the Hello closes without a reply and consumes nothing":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    for code in [ecTransport, ecNotAuthorised, ecInvalidParams]:
      let f = acceptHello(endpoint, store, protocolErrorMsg(code), Second).error
      check f.peer and f.code == code and f.reason == hrPeer
    check store.validate(t, Second).isOk
    # Only a well-formed one: code 0 is an envelope failure, answered.
    let bad = wire(kindMap(6, ("code", cbor(0'u64))))
    let g = acceptHello(endpoint, store, bad, Second).error
    check g.code == ecInvalidParams and not g.peer
    check store.validate(t, Second).isOk

  test "[TRN-0319] [TRN-0079] a failure after redemption does not restore the ticket":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    let est = acceptHello(endpoint, store, helloWith(t), Second).get
    check est.binding.endpoint == "ep-1"
    # The established session then fails.
    var callee = calleeConn(storageBoundary)
    check closeCode(callee.receive(@[0xff'u8])) == Opt.some(ecInvalidParams)
    check store.len == 0
    check store.validate(t, Second).error == tfUnknown
    check acceptHello(endpoint, store, helloWith(t), Second).error.code ==
      ecNotAuthorised

  test "[TRN-0268] [TRN-0261] a Hello must fit the peer's frame maximum, or the establishment fails":
    let t = ticketBytes(1)
    let req = helloRequest("storage_module", t, root).get
    check helloRequest("storage_module", t, root, uint32(req.len)).get == req
    check helloRequest("storage_module", t, root, uint32(req.len - 1)).error.kind ==
      eeTooLarge
    # The callee's response is checked before redemption: a failure consumes
    # nothing and establishes nothing.
    var store: TicketStore[RouteBinding]
    let live = store.issue(routeBinding(), 0, 100 * Second).get
    let f = acceptHello(endpoint, store, helloWith(live), Second, smallPeer(8)).error
    check f.code == ecModule and f.reason == hrSend and not f.peer
    check store.validate(live, Second).isOk
    check acceptHello(endpoint, store, helloWith(live), Second).isOk

  test "[TRN-0081] [TRN-0082] a Hello after establishment closes the connection":
    var (caller, callee) = pair()
    let hello = encodeMessage(samples()[0]).get
    check closeCode(callee.receive(hello)) == Opt.some(ecInvalidParams)
    check closeCode(caller.receive(hello)) == Opt.some(ecInvalidParams)

suite "trn.ticket: the random-256 route-ticket profile (TRANSPORT §8.1.1)":
  test "[TRN-0169] a ticket that collides with a live one is discarded and regenerated":
    var store: TicketStore[RouteBinding]
    var calls = 0
    let repeating: RandomSource = proc(dest: var openArray[byte]): bool =
      inc calls
      for i in 0 ..< dest.len:
        dest[i] = byte(if calls <= 2: 7 else: calls)
      true
    let a = store.issue(routeBinding(), 0, 100 * Second, repeating).get
    let b = store.issue(routeBinding(), 0, 100 * Second, repeating).get
    check a != b
    check calls == 3
    let stuck: RandomSource = proc(dest: var openArray[byte]): bool =
      for i in 0 ..< dest.len:
        dest[i] = 7
      true
    check store.issue(routeBinding(), 0, 100 * Second, stuck).isErr
    let broken: RandomSource = proc(dest: var openArray[byte]): bool =
      false
    check store.issue(routeBinding(), 0, 100 * Second, broken).isErr

  test "[TRN-0170] the store keeps BLAKE3-256 digests, never tickets":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    let keys = toSeq(store.digests())
    check keys == @[blake3(t)]
    check keys[0] != t
    check t.len == TicketBytes
    check RouteTicketProfile == "logos.route-ticket.random-256"
    # The OS generator gives distinct tickets.
    let u = store.issue(routeBinding(), 0, 100 * Second).get
    check u != t

  test "[TRN-0172] [TRN-0178] a ticket expires with its route and within 60 s; expired records are deleted":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 120 * Second).get
    check store.validate(t, 60 * Second - 1).isOk
    check store.validate(t, 60 * Second).error == tfExpired
    check store.len == 0
    let u = store.issue(routeBinding(), 0, 10 * Second).get
    check store.validate(u, 10 * Second - 1).isOk
    check store.redeem(u, 10 * Second).error == tfExpired
    check store.issue(routeBinding(), 50 * Second, 50 * Second).isErr
    discard store.issue(routeBinding(), 0, Second).get
    discard store.issue(routeBinding(), 0, 30 * Second).get
    store.sweep(2 * Second)
    check store.len == 1

  test "[TRN-0157] [TRN-0178] revoked records are deleted and consumed ones stay unusable":
    var store: TicketStore[RouteBinding]
    let t = store.issue(routeBinding(), 0, 100 * Second).get
    discard store.issue(routeBinding(endpoint = "ep-2"), 0, 100 * Second).get
    check store.revoke(
      proc(b: RouteBinding): bool =
        b.endpoint == "ep-1"
    ) == 1
    check store.len == 1
    check acceptHello(endpoint, store, helloWith(t), Second).error.code ==
      ecNotAuthorised
    let u = store.issue(routeBinding(), 0, 100 * Second).get
    check store.redeem(u, Second).isOk
    check store.validate(u, Second).error == tfUnknown

suite "trn.request: calls and payload commitments (TRANSPORT §4.1, §4.2, §8.3)":
  test "[IFC-0426] [TRN-0085] [TRN-0089] [TRN-0090] [TRN-0091] [TRN-0092] [TRN-0093] a call round trip carries recomputable commitments":
    var (caller, callee) = pair()
    let (id, req) = caller.request("exists", params()).get
    let acts = callee.receive(req)
    let r = dispatched(acts)
    check r.len == 1 and r[0].id == id and r[0].params == params()
    let want = commitmentOf("storage.exists_request", params())
    check r[0].commitment == want
    check want.subtreeRoot == subtreeOf("storage.exists_request")
    let resp = callee.respond(id, okExists()).get
    let m = decodeMessage(resp).get.response
    check m.id == id
    check m.commitment == commitmentOf("storage.exists_response", okExists().response)
    let evs = caller.receive(resp)
    check evs.len == 1 and evs[0].id == id and evs[0].outcome.ok
    check evs[0].outcome.response == okExists().response

  test "[TRN-0095] [TRN-0293] [TRN-0295] [TRN-0296] a subtree or value root that does not match closes the session":
    let good = commitmentOf("storage.exists_request", params())
    var badValue = good
    badValue.valueRoot[0] = badValue.valueRoot[0] xor 1
    var badSubtree = good
    badSubtree.subtreeRoot = subtreeOf("storage.exists_response")
    for c in [badValue, badSubtree]:
      var (_, callee) = pair()
      let acts = callee.receive(rawRequest(0, "exists", params(), c))
      check dispatched(acts).len == 0
      check closeCode(acts) == Opt.some(ecInvalidParams)
    # A missing or short commitment fails the envelope.
    let short = toCbor(samples()[1]).with(
        "commitment",
        cborMap(
          (cbor("schema_subtree_root"), cbor(newSeq[byte](31))),
          (cbor("value_root"), cbor(newSeq[byte](32))),
        ),
      )
    check envelopeError(short).field == "commitment"
    check envelopeError(toCbor(samples()[1]).without("commitment")).field == "commitment"

  test "[TRN-0159] [TRN-0292] [TRN-0293] [TRN-0294] [TRN-0297] [TRN-0298] the subtree root first, then the schema: a schema-invalid Request fails its call and keeps the session":
    let bad = cborMap((cbor("cid"), cbor(5'u64)))
    var (_, callee) = pair()
    # The value root is garbage: a schema-invalid payload has no value root to
    # compare, so the outcome is the schema failure, not a root mismatch.
    let acts = callee.receive(
      rawRequest(
        0,
        "exists",
        bad,
        PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_request")),
      )
    )
    check callee.state == csOpen
    check dispatched(acts).len == 0
    let resp = sent(acts)[0].response
    check not resp.ok and resp.failure.code == ecInvalidParams
    check resp.failure.detail.isSome
    let r = storageBoundary.acceptRequest(
      decodeMessage(
        rawRequest(
          0,
          "exists",
          bad,
          PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_request")),
        )
      ).get.request
    )
    check r.error.cause == rcSchema and r.error.kind == rjRespond
    # The session goes on.
    check dispatched(callee.receive(requestFor(1))).len == 1
    var (_, callee2) = pair()
    check closeCode(
      callee2.receive(
        rawRequest(
          0,
          "exists",
          bad,
          PayloadCommitment(subtreeRoot: subtreeOf("storage.space_request")),
        )
      )
    ) == Opt.some(ecInvalidParams)

  test "[TRN-0003] a rejected payload fails as it would in direct mode":
    let bad = cborMap((cbor("cid"), cbor(5'u64)))
    var (_, callee) = pair()
    let acts = callee.receive(
      rawRequest(
        3,
        "exists",
        bad,
        PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_request")),
      )
    )
    let direct =
      validator(storage).checkParams("exists", encodeCbor(bad)).error.toFailure
    check sent(acts)[0].response.failure == direct
    check sent(acts)[0].response.id == 3

  test "[TRN-0097] [TRN-0300] [TRN-0296] a schema-invalid response-ok or Event closes; the call gets TRANSPORT_ERROR and the Event is not delivered":
    var (caller, _) = pair()
    let (id, _) = caller.request("exists", params()).get
    let bad = cborMap((cbor("exists"), cbor(5'u64)))
    let resp = rawResponse(
      id, bad, PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_response"))
    )
    let evs = caller.receive(resp)
    check evs[0].id == id and evs[0].outcome.failure.code == ecTransport
    check closeCode(evs) == Opt.some(ecInvalidParams)
    check evs.filterIt(it.kind == ceResponse).len == 1
    # An Event: the same, and no ceEvent.
    var (caller2, callee2) = pair()
    active(caller2, callee2, 1, "storage.upload_done_event")
    discard caller2.request("exists", params()).get
    let ev = rawEvent(
      1,
      "storage.upload_done_event",
      cborMap((cbor("cid"), cbor(7'u64))),
      PayloadCommitment(subtreeRoot: subtreeOf("storage.upload_done_event")),
    )
    let evs2 = caller2.receive(ev)
    check evs2.filterIt(it.kind == ceEvent).len == 0
    check evs2[0].outcome.failure.code == ecTransport
    check closeCode(evs2) == Opt.some(ecInvalidParams)
    check caller2.state == csClosed

  test "[TRN-0299] a resource-limit failure is never reported as a root mismatch":
    # A payload over P with a wrong value root: the depth check fails first and
    # is reported as such, with no detail; no root is compared.
    let l = transportLimits(payloadDepth = MinMaxDepth).get
    let deep = cborMap((cbor("cid"), nest(cbor("x"), MinMaxDepth)))
    var c = commitmentOf("storage.exists_request", params())
    c.valueRoot[0] = c.valueRoot[0] xor 1
    let b = rawRequest(0, "exists", deep, c)
    check decodeMessage(b, MinMaxDepth).error.kind == eeTooDeep
    var callee = calleeConn(storageBoundary, l)
    let acts = callee.receive(b)
    check closeMessage(acts).get.detail.isNone
    check "differs" notin acts[0].close.msg
    check "too-deep" in acts[0].close.msg
    # The boundary classifies each failure by the check that failed.
    let good = commitmentOf("storage.exists_request", params())
    var badValue = good
    badValue.valueRoot[0] = badValue.valueRoot[0] xor 1
    proc causeOf(c: PayloadCommitment, p = params()): RejectCause =
      storageBoundary.acceptRequest(
        Request(id: 0, methodName: "exists", params: p, commitment: c)
      ).error.cause

    check causeOf(badValue) == rcValueRoot
    check causeOf(PayloadCommitment(subtreeRoot: subtreeOf("storage.space_request"))) ==
      rcSubtreeRoot
    check causeOf(badValue, cborMap((cbor("cid"), cbor(1'u64)))) == rcSchema

  test "[TRN-0292] [TRN-0204] method resolution and the route's method scope come before the payload checks":
    let scoped = storageBoundary.withAccess(["space"], [])
    check scoped.allowsMethod("space") and not scoped.allowsMethod("exists")
    check storageBoundary.allowsMethod("exists")
    var callee = calleeConn(scoped)
    # In the contract but outside the scope: NOT_AUTHORISED without dispatch,
    # before the commitment is looked at; the session stays.
    let acts = callee.receive(rawRequest(0, "exists", params(), PayloadCommitment()))
    check dispatched(acts).len == 0
    let resp = sent(acts)[0].response
    check resp.failure.code == ecNotAuthorised and resp.failure.detail.isNone
    check callee.state == csOpen
    # Outside the contract: METHOD_NOT_FOUND, whatever the scope says.
    let wide = storageBoundary.withAccess(["space", "nope"], [])
    var callee2 = calleeConn(wide)
    check sent(callee2.receive(rawRequest(0, "nope", cborMap(), PayloadCommitment())))[
      0
    ].response.failure.code == ecMethodNotFound
    # In scope: the payload checks run as before.
    var caller = callerConn(storageBoundary, firstId = 5)
    let (_, req) = caller.request("space", cborMap()).get
    check dispatched(callee.receive(req)).len == 1

  test "[IFC-0427] [TRN-0100] [TRN-0101] [TRN-0102] [TRN-0103] failures travel as response-err; schema-defined failures stay results":
    var (caller, callee) = pair()
    let (id, req) = caller.request("exists", params()).get
    discard callee.receive(req)
    let detail = invalidParamsDetail(iprSchemaMismatch)
    let f = InvocationFailure(
      code: ecInvalidParams, message: Opt.some("bad cid"), detail: Opt.some(detail)
    )
    let resp = callee.respond(id, CallOutcome(ok: false, failure: f)).get
    let m = decodeMessage(resp).get.response
    check not m.ok and m.failure == f
    check caller.receive(resp)[0].outcome.failure == f
    # A domain failure the response schema defines is an ordinary result.
    let (id2, req2) = caller.request("exists", params("missing")).get
    discard callee.receive(req2)
    let notThere =
      CallOutcome(ok: true, response: cborMap((cbor("exists"), cbor(false))))
    check decodeMessage(callee.respond(id2, notThere).get).get.response.ok
    # A provider failure the envelope cannot carry is MODULE_ERROR.
    let (id3, req3) = caller.request("exists", params()).get
    discard callee.receive(req3)
    let zero = CallOutcome(ok: false, failure: InvocationFailure(code: ecOk))
    check decodeMessage(callee.respond(id3, zero).get).get.response.failure.code ==
      ecModule
    # So is a result outside the response schema.
    let (id4, req4) = caller.request("exists", params()).get
    discard callee.receive(req4)
    let wrong = CallOutcome(ok: true, response: cborMap((cbor("exists"), cbor(1'u64))))
    check decodeMessage(callee.respond(id4, wrong).get).get.response.failure.code ==
      ecModule

  test "[TRN-0160] [TRN-0203] [TRN-0204] names resolve under the selected contract only, before any payload check":
    let b = boundary(sensor, sensorIface).get
    check b.knowsMethod("snapshot")
    check not b.knowsMethod("configure")
    var callee = calleeConn(b)
    let acts =
      callee.receive(rawRequest(0, "configure", cborMap(), PayloadCommitment()))
    let resp = sent(acts)[0].response
    check resp.failure.code == ecMethodNotFound
    check callee.state == csOpen
    check dispatched(acts).len == 0
    # An unknown name fails before its payload is looked at.
    var (_, callee2) = pair()
    let garbage = cborMap((cbor("x"), cborTag(9, cborNull())))
    let r2 = sent(callee2.receive(rawRequest(0, "nope", garbage, PayloadCommitment())))
    check r2[0].response.failure.code == ecMethodNotFound
    let full = boundary(sensor, sensor.primary.root).get
    check full.knowsMethod("configure") and full.knowsMethod("snapshot")
    check boundary(sensor, root).isErr

  test "[TRN-0091] logos.schema is committed under the common schema and answered by the boundary":
    var (caller, callee) = pair()
    let (id, req) = caller.request("schema", cborMap()).get
    let acts = callee.receive(req)
    check acts[0].kind == caDispatch and acts[0].introspection
    let common = pinnedContext().commonModel
    let r = schemaSet(common).normalize(0, "logos.schema_request", cborMap()).get
    check acts[0].request.commitment.subtreeRoot == r.subtreeRoot
    let answer = schemaResponse(storage, root).get
    let resp = callee.respond(id, CallOutcome(ok: true, response: answer)).get
    check caller.receive(resp)[0].outcome.response == answer

suite "trn.cancel: cancellation (TRANSPORT §6)":
  test "[TRN-0130] [TRN-0131] [TRN-0316] a Cancel before the terminal Response commits exactly one CANCELLED, without waiting for the provider":
    var (caller, callee) = pair()
    let (id, req) = caller.request("exists", params()).get
    discard callee.receive(req)
    let acts = callee.receive(caller.cancel(id).get)
    let s = sent(acts)
    check s.len == 1 and s[0].response.id == id
    check s[0].response.failure.code == ecCancelled
    check acts.anyIt(it.kind == caStop and it.id == id)
    check callee.respond(id, okExists()).isNone
    check callee.inFlight == 0
    let evs = caller.receive(acts[0].bytes)
    check evs[0].outcome.failure.code == ecCancelled
    check caller.pendingCalls == 0

  test "[TRN-0132] a Cancel after the terminal Response changes nothing":
    var (caller, callee) = pair()
    let (id, req) = caller.request("exists", params()).get
    discard callee.receive(req)
    let resp = callee.respond(id, okExists()).get
    let cancel = caller.cancel(id).get
    check callee.receive(cancel).len == 0
    check caller.receive(resp)[0].outcome.ok
    check caller.cancel(id).isNone

  test "[TRN-0133] a Cancel for no in-flight request is ignored and changes no state":
    var (_, callee) = pair()
    discard callee.receive(requestFor(4))
    let before = callee.inFlight
    for id in [0'u64, 3, 9, high(uint64)]:
      let c = encodeMessage(Message(kind: mkCancel, cancel: Cancel(id: id))).get
      check callee.receive(c).len == 0
    check callee.inFlight == before and callee.state == csOpen
    # Cancel ids are not Request ids: 9 did not move the sequence.
    check dispatched(callee.receive(requestFor(5))).len == 1

  test "[TRN-0313] invocation-scoped Events stop once Cancel is processed or the terminal Response is committed":
    var (caller, callee) = pair()
    active(caller, callee, 1, "storage.upload_progress_event")
    active(caller, callee, 2, "storage.upload_progress_event")
    active(caller, callee, 3, "storage.started_event")
    let progress = cborMap(
      (cbor("session"), cbor("s")),
      (cbor("bytes_sent"), cbor(1'u64)),
      (cbor("bytes_total"), cbor(2'u64)),
    )
    let (a, ra) = caller.request("exists", params()).get
    discard callee.receive(ra)
    # Every active subscription to that event on this connection, and no other.
    let frames = callee.publishScoped(a, "storage.upload_progress_event", progress).get
    check frames.len == 2
    for i, f in frames:
      let e = decodeMessage(f).get.event
      check e.sub == uint64(i + 1)
      check e.commitment == commitmentOf("storage.upload_progress_event", progress)
      let evs = caller.receive(f)
      check evs[0].kind == ceEvent and evs[0].id == uint64(i + 1)
    check callee.publishScoped(
      a, "storage.upload_done_event", cborMap((cbor("cid"), cbor("c")))
    ).get.len == 0
    # The terminal Response closes the destination; the subscriptions stay.
    discard callee.respond(a, okExists()).get
    let after = callee.publishScoped(a, "storage.upload_progress_event", progress)
    check after.error.kind == peNoDestination and after.error.code == ecNotReady
    check callee.publish(1, progress).isOk
    # So does a processed Cancel.
    let (b, rb) = caller.request("exists", params()).get
    discard callee.receive(rb)
    check callee.publishScoped(b, "storage.upload_progress_event", progress).isOk
    discard callee.receive(caller.cancel(b).get)
    check callee.publishScoped(b, "storage.upload_progress_event", progress).error.kind ==
      peNoDestination
    # Outside the selected contract, or invalid data.
    let (c, rc) = caller.request("exists", params()).get
    discard callee.receive(rc)
    let other = callee.publishScoped(c, "metrics.tick_event", cborMap())
    check other.error.kind == peNotInContract and other.error.code == ecNotAuthorised
    let invalid = callee.publishScoped(c, "storage.upload_progress_event", cborMap())
    check invalid.error.kind == peInvalid and invalid.error.code == ecInvalidParams

suite "trn.multiplex: concurrent requests (TRANSPORT §2.2, §7)":
  test "[TRN-0136] [TRN-0137] [TRN-0141] [TRN-0059] responses may come out of order":
    var (caller, callee) = pair()
    let (a, ra) = caller.request("space", cborMap()).get
    let (b, rb) = caller.request("exists", params()).get
    check dispatched(callee.receive(ra)).len == 1
    check dispatched(callee.receive(rb)).len == 1
    let space = cborMap(
      (
        cbor("info"),
        cborMap(
          (cbor("quota"), cbor(10'u64)),
          (cbor("used"), cbor(1'u64)),
          (cbor("available"), cbor(9'u64)),
        ),
      )
    )
    let second = callee.respond(b, okExists()).get
    let first = callee.respond(a, CallOutcome(ok: true, response: space)).get
    check caller.receive(second)[0].id == b
    let evs = caller.receive(first)
    check evs[0].id == a and evs[0].outcome.response == space

  test "[TRN-0138] [TRN-0140] Request ids strictly increase; gaps are allowed, repeats close":
    var (caller, _) = pair()
    var ids: seq[uint64]
    for _ in 0 .. 2:
      ids.add(caller.request("exists", params()).get[0])
    check ids == @[0'u64, 1, 2]
    var (_, callee) = pair()
    check dispatched(callee.receive(requestFor(5))).len == 1
    check dispatched(callee.receive(requestFor(9))).len == 1
    for repeat in [9'u64, 7]:
      var (_, c2) = pair()
      discard c2.receive(requestFor(9))
      let acts = c2.receive(requestFor(repeat))
      check dispatched(acts).len == 0
      check closeCode(acts) == Opt.some(ecInvalidParams)

  test "[TRN-0139] with no larger id the caller closes without sending":
    var caller = callerConn(storageBoundary, firstId = high(uint64))
    let (id, _) = caller.request("exists", params()).get
    check id == high(uint64)
    check caller.request("exists", params()).isErr
    check caller.state == csClosed

  test "[IFC-0428] [TRN-0078] closing fails pending calls with TRANSPORT_ERROR and replays nothing":
    var (caller, _) = pair()
    discard caller.request("exists", params()).get
    discard caller.request("space", cborMap()).get
    let evs = caller.close()
    check evs.filterIt(it.kind == ceResponse).mapIt(it.outcome.failure.code) ==
      @[ecTransport, ecTransport]
    check caller.request("exists", params()).isErr
    check caller.pendingCalls == 0

suite "trn.subscribe: subscriptions (TRANSPORT §5.1)":
  test "[TRN-0106] [TRN-0301] [TRN-0114] [TRN-0115] [TRN-0116] Subscribe, events, Unsubscribe":
    var (caller, callee) = pair()
    let sub = caller.subscribe(1, "storage.started_event").get
    let acts = callee.receive(sub)
    check acts[0].kind == caSubscribe and acts[0].subId == 1
    check callee.publish(1, cborMap()).isErr # not active before the result
    let activated = callee.subscriptionResult(1).get
    check caller.receive(activated)[0].op == mkSubscribe
    let ev = callee.publish(1, cborMap()).get
    let evs = caller.receive(ev)
    check evs[0].kind == ceEvent and evs[0].event == "storage.started_event"
    check decodeMessage(ev).get.event.commitment ==
      commitmentOf("storage.started_event", cborMap())
    # The same event under another id.
    discard callee.receive(caller.subscribe(2, "storage.started_event").get)
    discard caller.receive(callee.subscriptionResult(2).get)
    let unsub = caller.unsubscribe(1).get
    check callee.receive(unsub)[0].kind == caUnsubscribe
    # An Event accepted before the result is committed before it, in order.
    let late = callee.publish(1, cborMap()).get
    let done = callee.subscriptionResult(1).get
    check caller.receive(late)[0].kind == ceEvent
    check decodeMessage(done).get.subscriptionResult.operation == mkUnsubscribe
    check caller.receive(done)[0].op == mkUnsubscribe
    check callee.publish(1, cborMap()).isErr
    check callee.publish(2, cborMap()).isOk

  test "[TRN-0107] [TRN-0108] the caller keeps one control operation per id, and never reuses an id":
    var (caller, callee) = pair()
    discard callee.receive(caller.subscribe(1, "storage.started_event").get)
    check caller.unsubscribe(1).error.code == ecInvalidParams
    check caller.subscribe(1, "storage.started_event").error.code == ecInvalidParams
    check caller.subscribe(2, "metrics.nope").error.code == ecNotAuthorised
    # An id stays used once its subscription failed or ended.
    discard caller.receive(callee.subscriptionResult(1).get)
    discard callee.receive(caller.unsubscribe(1).get)
    discard caller.receive(callee.subscriptionResult(1).get)
    check caller.subscribe(1, "storage.started_event").error.code == ecInvalidParams
    # 2 was refused locally and never sent: it is still free.
    check caller.subscribe(2, "storage.started_event").isOk

  test "[TRN-0110] [TRN-0113] [TRN-0305] an event outside the selected contract fails with NOT_AUTHORISED; failures change nothing but use the id":
    let
      watchIface = "_interface = \"watch\"\nwatch.tick_event = {\n  n: uint64,\n}\n"
      watchRoot = acceptContractSet(watchIface).get.primary.root
      watchModule =
        "_module = \"watcher\"\n_implements = [\n  h'" & toHex(watchRoot) &
        "',\n]\nwatcher.alarm_event = {}\n"
      watcher = acceptContractSet(watchModule, [watchIface]).get
      b = boundary(watcher, watchRoot).get
    check b.knowsEvent("watch.tick_event")
    check not b.knowsEvent("watcher.alarm_event")
    check boundary(watcher, watcher.primary.root).get.knowsEvent("watcher.alarm_event")
    var callee = calleeConn(b)
    let r = sent(callee.receive(subscribeMsg(1, "watcher.alarm_event")))[0]
    check r.subscriptionResult.id == 1
    check r.subscriptionResult.operation == mkSubscribe
    check r.subscriptionResult.failure.get.code == ecNotAuthorised
    check callee.subscriptions == 0
    # No subscription was registered, but the id is used: reusing it for a
    # selected event fails with INVALID_PARAMS.
    let again = sent(callee.receive(subscribeMsg(1, "watch.tick_event")))[0]
    check again.subscriptionResult.failure.get.code == ecInvalidParams
    # A failed result for a decided Subscribe leaves the state as it was: not
    # active.
    check callee.receive(subscribeMsg(2, "watch.tick_event"))[0].kind == caSubscribe
    check callee.subscriptionResult(
      2, Opt.some(InvocationFailure(code: ecNotAuthorised))
    ).isSome
    check callee.publish(2, cborMap((cbor("n"), cbor(1'u64)))).error.kind ==
      peNoDestination
    check callee.usedSubscriptionIds == 2

  test "[TRN-0111] [TRN-0112] the route's event-subscription scope is enforced before activation":
    let scoped = storageBoundary.withAccess([], ["storage.started_event"])
    check scoped.allowsEvent("storage.started_event")
    check not scoped.allowsEvent("storage.upload_done_event")
    var callee = calleeConn(scoped)
    check callee.receive(subscribeMsg(1, "storage.started_event"))[0].kind == caSubscribe
    let r = sent(callee.receive(subscribeMsg(2, "storage.upload_done_event")))[0]
    check r.subscriptionResult.failure.get.code == ecNotAuthorised
    check callee.subscriptions == 1
    # A name outside the selected contract fails the same way.
    let unknown = sent(callee.receive(subscribeMsg(3, "metrics.tick_event")))[0]
    check unknown.subscriptionResult.failure.get.code == ecNotAuthorised

  test "[TRN-0302] [TRN-0303] [TRN-0304] an operation over an uncommitted result closes, with no SubscriptionResult":
    for second in [
      subscribeMsg(1, "storage.started_event"),
      unsubscribeMsg(1),
      # The overlap check comes before the identifier and event checks.
      subscribeMsg(1, "metrics.tick_event"),
    ]:
      var (_, callee) = pair()
      check callee.receive(subscribeMsg(1, "storage.started_event"))[0].kind ==
        caSubscribe
      let acts = callee.receive(second)
      check sent(acts).len == 0
      check closeCode(acts) == Opt.some(ecInvalidParams)
      check callee.state == csClosed
    # The same over an outstanding Unsubscribe.
    var (caller, callee) = pair()
    active(caller, callee, 1, "storage.started_event")
    check callee.receive(unsubscribeMsg(1))[0].kind == caUnsubscribe
    let acts = callee.receive(subscribeMsg(1, "storage.started_event"))
    check sent(acts).len == 0 and closeCode(acts) == Opt.some(ecInvalidParams)
    # Once the result is committed, the next operation is no overlap.
    var (caller2, callee2) = pair()
    active(caller2, callee2, 1, "storage.started_event")
    check callee2.receive(unsubscribeMsg(1))[0].kind == caUnsubscribe
    discard callee2.subscriptionResult(1).get
    let late = sent(callee2.receive(unsubscribeMsg(1)))[0]
    check late.subscriptionResult.failure.get.code == ecInvalidParams
    check callee2.state == csOpen

  test "[TRN-0302] [TRN-0305] [TRN-0306] [TRN-0301] reused ids and Unsubscribe without an active subscription fail with INVALID_PARAMS; active state is unchanged":
    var (caller, callee) = pair()
    # Reuse while active: refused, the subscription stays active.
    active(caller, callee, 1, "storage.started_event")
    let r1 = sent(callee.receive(subscribeMsg(1, "storage.started_event")))[0]
    check r1.subscriptionResult.failure.get.code == ecInvalidParams
    check r1.subscriptionResult.operation == mkSubscribe
    check callee.publish(1, cborMap()).isOk
    # Reuse after the subscription ended.
    discard callee.receive(unsubscribeMsg(1))
    discard callee.subscriptionResult(1).get
    let r2 = sent(callee.receive(subscribeMsg(1, "storage.started_event")))[0]
    check r2.subscriptionResult.failure.get.code == ecInvalidParams
    # Reuse after a failed Subscribe; the identifier check comes before the
    # event is resolved, so an unknown event gives INVALID_PARAMS too.
    discard callee.receive(subscribeMsg(2, "storage.started_event"))
    discard
      callee.subscriptionResult(2, Opt.some(InvocationFailure(code: ecNotAuthorised)))
    for event in ["storage.started_event", "metrics.tick_event"]:
      let r = sent(callee.receive(subscribeMsg(2, event)))[0]
      check r.subscriptionResult.failure.get.code == ecInvalidParams
    # Unsubscribe naming no active subscription: unknown, ended, failed.
    for id in [9'u64, 1, 2]:
      let r = sent(callee.receive(unsubscribeMsg(id)))[0]
      check r.subscriptionResult.failure.get.code == ecInvalidParams
      check r.subscriptionResult.operation == mkUnsubscribe
    check callee.subscriptions == 0
    check callee.state == csOpen

suite "trn.correlation: Response, SubscriptionResult and Event correlation (TRANSPORT §3.4)":
  test "[TRN-0280] [TRN-0283] [TRN-0284] a Response must name a transmitted Request with no terminal Response; anything else closes":
    # Never sent.
    var (caller, _) = pair()
    check closeCode(caller.receive(encodeMessage(samples()[2]).get)) ==
      Opt.some(ecInvalidParams)
    # Below the highest transmitted id but never sent: gaps do not correlate.
    var gap = callerConn(storageBoundary, firstId = 5)
    let (id, _) = gap.request("exists", params()).get
    check id == 5
    let stray = encodeMessage(
      Message(
        kind: mkResponse,
        response: Response(id: 3, ok: false, failure: InvocationFailure(code: ecModule)),
      )
    ).get
    let evs = gap.receive(stray)
    check closeCode(evs) == Opt.some(ecInvalidParams)
    check evs[0].id == 5 and evs[0].outcome.failure.code == ecTransport
    # A duplicate.
    var (caller2, callee2) = pair()
    let (id2, req2) = caller2.request("exists", params()).get
    discard callee2.receive(req2)
    let resp = callee2.respond(id2, okExists()).get
    check caller2.receive(resp)[0].outcome.ok
    check closeCode(caller2.receive(resp)) == Opt.some(ecInvalidParams)
    # Sending Cancel is not receiving a terminal Response.
    var (caller3, callee3) = pair()
    let (id3, req3) = caller3.request("exists", params()).get
    discard callee3.receive(req3)
    discard caller3.cancel(id3).get
    check caller3.pendingCalls == 1
    check caller3.receive(callee3.respond(id3, okExists()).get)[0].outcome.ok

  test "[TRN-0281] [TRN-0283] [TRN-0284] a SubscriptionResult must match the id and operation of an outstanding operation":
    var (caller, _) = pair()
    check closeCode(caller.receive(encodeMessage(samples()[9]).get)) ==
      Opt.some(ecInvalidParams)
    # The right id, the wrong operation.
    var (caller2, callee2) = pair()
    discard callee2.receive(caller2.subscribe(3, "storage.started_event").get)
    check closeCode(caller2.receive(encodeMessage(samples()[10]).get)) ==
      Opt.some(ecInvalidParams)
    # A duplicate.
    var (caller3, callee3) = pair()
    discard callee3.receive(caller3.subscribe(3, "storage.started_event").get)
    let ok3 = callee3.subscriptionResult(3).get
    check caller3.receive(ok3)[0].kind == ceSubscription
    check closeCode(caller3.receive(ok3)) == Opt.some(ecInvalidParams)

  test "[TRN-0282] [TRN-0283] [TRN-0284] an Event must name an active subscription and its event":
    let ev = encodeMessage(samples()[6]).get # sub 3, storage.started_event
    # Before the successful Subscribe completes.
    var (caller, callee) = pair()
    discard callee.receive(caller.subscribe(3, "storage.started_event").get)
    check closeCode(caller.receive(ev)) == Opt.some(ecInvalidParams)
    # Another event than the subscription's.
    var (caller2, callee2) = pair()
    active(caller2, callee2, 3, "storage.upload_done_event")
    check closeCode(caller2.receive(ev)) == Opt.some(ecInvalidParams)
    # While Unsubscribe is outstanding: still valid; after it completes: not.
    var (caller3, callee3) = pair()
    active(caller3, callee3, 3, "storage.started_event")
    discard callee3.receive(caller3.unsubscribe(3).get)
    check caller3.receive(ev)[0].kind == ceEvent
    discard caller3.receive(callee3.subscriptionResult(3).get)
    check closeCode(caller3.receive(ev)) == Opt.some(ecInvalidParams)

  test "[TRN-0285] [TRN-0286] an abandoned call's first late Response is validated, then discarded; the next one is a duplicate":
    var (caller, callee) = pair()
    let (id, req) = caller.request("exists", params()).get
    discard callee.receive(req)
    check caller.abandon(id)
    check not caller.abandon(id)
    check caller.pendingCalls == 0 and caller.outstandingCalls == 1
    # A Cancel can still be sent for it.
    check caller.cancel(id).isSome
    let resp = callee.respond(id, okExists()).get
    check caller.receive(resp).len == 0
    check caller.state == csOpen and caller.outstandingCalls == 0
    check closeCode(caller.receive(resp)) == Opt.some(ecInvalidParams)
    # The late Response is checked against the retained response declaration:
    # an invalid one closes even though nobody awaits it.
    var (caller2, _) = pair()
    let (id2, _) = caller2.request("exists", params()).get
    discard caller2.request("space", cborMap()).get
    check caller2.abandon(id2)
    let bad = rawResponse(
      id2,
      cborMap((cbor("exists"), cbor(5'u64))),
      PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_response")),
    )
    let evs = caller2.receive(bad)
    check closeCode(evs) == Opt.some(ecInvalidParams)
    # Only the awaited call is reported.
    check evs.filterIt(it.kind == ceResponse).mapIt(it.id) == @[1'u64]
    # A late error Response is validated as an error payload and discarded.
    var (caller3, callee3) = pair()
    let (id3, req3) = caller3.request("exists", params()).get
    discard callee3.receive(req3)
    check caller3.abandon(id3)
    let cancelled = sent(callee3.receive(caller3.cancel(id3).get))
    check caller3.receive(encodeMessage(cancelled[0]).get).len == 0
    check caller3.outstandingCalls == 0

  test "[TRN-0287] [TRN-0288] [TRN-0289] an abandoned subscription: results still update state, Events are validated but not delivered, Unsubscribe stops it":
    var (caller, callee) = pair()
    discard callee.receive(caller.subscribe(1, "storage.upload_done_event").get)
    check caller.abandonSubscription(1)
    check not caller.abandonSubscription(9)
    # The late successful result still activates it.
    check caller.receive(callee.subscriptionResult(1).get)[0].op == mkSubscribe
    let ev = callee.publish(1, cborMap((cbor("cid"), cbor("c")))).get
    check caller.receive(ev).len == 0
    check caller.state == csOpen
    # An invalid Event for it still closes.
    let bad = rawEvent(
      1,
      "storage.upload_done_event",
      cborMap((cbor("cid"), cbor(1'u64))),
      PayloadCommitment(subtreeRoot: subtreeOf("storage.upload_done_event")),
    )
    var (caller2, callee2) = pair()
    active(caller2, callee2, 1, "storage.upload_done_event")
    check caller2.abandonSubscription(1)
    check closeCode(caller2.receive(bad)) == Opt.some(ecInvalidParams)
    # Unsubscribe ends it; after that its Events are uncorrelated.
    discard callee.receive(caller.unsubscribe(1).get)
    check caller.receive(callee.subscriptionResult(1).get)[0].op == mkUnsubscribe
    check closeCode(caller.receive(ev)) == Opt.some(ecInvalidParams)

  test "[TRN-0291] [TRN-0307] retained correlation and id history are bounded, and nothing is forgotten while the connection stays open":
    # Caller: abandoned calls keep counting until their late Response arrives.
    let l = transportLimits(maxCalls = 2, maxSubscriptionIds = 2).get
    var caller = callerConn(storageBoundary, limits = l)
    var callee = calleeConn(storageBoundary, l)
    let (a, ra) = caller.request("exists", params()).get
    discard caller.request("space", cborMap()).get
    discard callee.receive(ra)
    check caller.abandon(a)
    let full = caller.request("exists", params())
    check full.error.code == ecModule
    discard caller.receive(callee.respond(a, okExists()).get)
    check caller.request("exists", params()).isOk
    # Callee: the id history closes the connection instead of forgetting an id.
    discard callee.receive(subscribeMsg(1, "storage.started_event"))
    discard callee.receive(subscribeMsg(2, "metrics.tick_event"))
    check callee.usedSubscriptionIds == 2
    # A reused id is still answered from the history.
    check sent(callee.receive(subscribeMsg(2, "storage.started_event")))[0].subscriptionResult.failure.get.code ==
      ecInvalidParams
    let acts = callee.receive(subscribeMsg(3, "storage.started_event"))
    check closeCode(acts) == Opt.some(ecTransport)
    check sent(acts).len == 0
    # Caller: the history refuses a new id locally.
    var c2 = callerConn(storageBoundary, limits = l)
    discard c2.subscribe(1, "storage.started_event").get
    discard c2.subscribe(2, "storage.started_event").get
    check c2.subscribe(3, "storage.started_event").error.code == ecModule

suite "trn.size: the sender's frame check (TRANSPORT §2.1)":
  test "[TRN-0261] [TRN-0262] [TRN-0263] an oversized Request is not sent, consumes no id and fails with MODULE_ERROR":
    # At the real 16 MiB floor.
    let huge = params("x".repeat(MinFrameLimit))
    var caller = callerConn(storageBoundary)
    let f = caller.request("exists", huge).error
    check f.code == ecModule
    check caller.pendingCalls == 0 and caller.state == csOpen
    check caller.request("exists", params()).get[0] == 0
    # A peer that established a larger maximum takes it.
    var larger = callerConn(
      storageBoundary, limits = transportLimits(peerFrameLimit = 2 * MinFrameLimit).get
    )
    check larger.request("exists", huge).isOk

  test "[TRN-0264] an oversized success Response becomes response-err MODULE_ERROR without detail; the session stays":
    let full = encodeMessage(
      Message(
        kind: mkResponse,
        response: Response(
          id: 0,
          ok: true,
          resultMap: space().response,
          commitment: commitmentOf("storage.space_response", space().response),
        ),
      )
    ).get
    var caller = callerConn(storageBoundary)
    var callee = calleeConn(storageBoundary, smallPeer(uint32(full.len - 1)))
    let (id, req) = caller.request("space", cborMap()).get
    discard callee.receive(req)
    let resp = callee.respond(id, space()).get
    let m = decodeMessage(resp).get.response
    check m.id == id and not m.ok
    check m.failure.code == ecModule and m.failure.detail.isNone
    check callee.state == csOpen
    check caller.receive(resp)[0].outcome.failure.code == ecModule
    # One that fits goes as it is.
    var callee2 = calleeConn(storageBoundary, smallPeer(uint32(full.len)))
    discard callee2.receive(
      rawRequest(
        0, "space", cborMap(), commitmentOf("storage.space_request", cborMap())
      )
    )
    check callee2.respond(0, space()).get == full

  test "[TRN-0265] [TRN-0266] an oversized Event is not committed and its publication reports failure":
    let data = cborMap((cbor("cid"), cbor("c".repeat(64))))
    var (caller, callee0) = pair()
    active(caller, callee0, 1, "storage.upload_done_event")
    let full = callee0.publish(1, data).get
    var callee = calleeConn(storageBoundary, smallPeer(uint32(full.len - 1)))
    discard callee.receive(subscribeMsg(1, "storage.upload_done_event"))
    discard callee.subscriptionResult(1).get
    let e = callee.publish(1, data).error
    check e.kind == peTooLarge and e.code == ecModule
    check callee.state == csOpen
    # A smaller Event still goes.
    check callee.publish(1, cborMap((cbor("cid"), cbor("c")))).isOk
    # Scoped publication: nothing is committed on the connection.
    discard callee.receive(requestFor(0))
    check callee.publishScoped(0, "storage.upload_done_event", data).error.kind ==
      peTooLarge

suite "trn.termination: route expiry or revocation on a live session (TRANSPORT §8.1)":
  test "[TRN-0163] [TRN-0321] [TRN-0323] [TRN-0324] [TRN-0326] admission stops, subscriptions end, then ProtocolError NOT_AUTHORISED and close":
    var (caller, callee) = pair()
    let (a, ra) = caller.request("exists", params()).get
    check dispatched(callee.receive(ra)).len == 1
    active(caller, callee, 1, "storage.started_event")
    discard callee.receive(caller.subscribe(2, "storage.started_event").get)
    active(caller, callee, 3, "storage.started_event")
    discard callee.receive(caller.unsubscribe(3).get)
    # Begin: each outstanding subscription operation gets its one result.
    let begun = sent(callee.beginTermination())
    check callee.state == csTerminating
    check begun.len == 2
    check begun[0].subscriptionResult.id == 2
    check begun[0].subscriptionResult.failure.get.code == ecNotAuthorised
    check begun[1].subscriptionResult.id == 3
    check begun[1].subscriptionResult.operation == mkUnsubscribe
    check begun[1].subscriptionResult.failure.isNone
    for m in begun:
      check caller.receive(encodeMessage(m).get)[0].kind == ceSubscription
    check callee.subscriptions == 0
    let p = callee.publish(1, cborMap())
    check p.error.kind == peEnded and p.error.code == ecNotAuthorised
    # A new Request: NOT_AUTHORISED, without dispatch or diagnostic.
    let (b, rb) = caller.request("exists", params()).get
    let acts = callee.receive(rb)
    check dispatched(acts).len == 0
    let rej = sent(acts)[0].response
    check rej.id == b and rej.failure.code == ecNotAuthorised
    check rej.failure.message.isNone and rej.failure.detail.isNone
    check caller.receive(encodeMessage(sent(acts)[0]).get)[0].outcome.failure.code ==
      ecNotAuthorised
    # A new Subscribe: a failed result NOT_AUTHORISED.
    let s4 = sent(callee.receive(caller.subscribe(4, "storage.started_event").get))[0]
    check s4.subscriptionResult.failure.get.code == ecNotAuthorised
    discard caller.receive(encodeMessage(s4).get)
    # In-flight work may still complete.
    check caller.receive(callee.respond(a, okExists()).get)[0].outcome.ok
    # Finish: ProtocolError NOT_AUTHORISED with nothing else, then close.
    let (c, _) = caller.request("exists", params()).get
    let fin = callee.finishTermination()
    let pe = closeMessage(fin).get
    check pe.code == ecNotAuthorised and pe.message.isNone and pe.detail.isNone
    check callee.state == csClosed
    let evs = caller.receive(fin[0].close.send.get)
    check evs.filterIt(it.kind == ceResponse).mapIt((it.id, it.outcome.failure.code)) ==
      @[(c, ecTransport)]
    check caller.state == csClosed

  test "[TRN-0322] termination waits for no Request and reads no unread one":
    var (caller, callee) = pair()
    let (a, ra) = caller.request("exists", params()).get
    discard callee.receive(ra)
    discard caller.request("exists", params()).get # never read by the callee
    discard callee.beginTermination()
    let fin = callee.finishTermination()
    check closeCode(fin) == Opt.some(ecNotAuthorised)
    check callee.inFlight == 0 and callee.state == csClosed
    let evs = caller.receive(fin[0].close.send.get)
    check evs.filterIt(it.kind == ceResponse).len == 2
    check evs[0].id == a and evs[0].outcome.failure.code == ecTransport
    # Callable without the first step too, and only once.
    var (_, callee2) = pair()
    check closeCode(callee2.finishTermination()) == Opt.some(ecNotAuthorised)
    check callee2.finishTermination().len == 0
    check callee2.beginTermination().len == 0

suite "trn.limits: per-connection resource limits (TRANSPORT §8.6)":
  test "[TRN-0381] [TRN-0383] [TRN-0385] admission comes before the resource; at the limit input waits or the connection closes, and nothing accepted is dropped":
    let l = transportLimits(maxInFlight = 2).get
    check l.maxInFlight == 2
    var callee = calleeConn(storageBoundary, l)
    check callee.admitsInput
    check dispatched(callee.receive(requestFor(0))).len == 1
    check dispatched(callee.receive(requestFor(1))).len == 1
    # Backpressure: the carrier stops reading.
    check not callee.admitsInput
    # A committed Response frees the slot.
    discard callee.respond(0, okExists()).get
    check callee.admitsInput
    check dispatched(callee.receive(requestFor(2))).len == 1
    # Fed past the limit anyway: the connection closes; the Request was never
    # accepted, and the accepted ones fail at the caller with TRANSPORT_ERROR.
    let acts = callee.receive(requestFor(3))
    check dispatched(acts).len == 0
    check closeCode(acts) == Opt.some(ecTransport)
    check not callee.admitsInput
    # Limits are finite and positive.
    for bad in [
      transportLimits(maxInFlight = 0),
      transportLimits(maxCalls = 0),
      transportLimits(maxSubscriptionIds = -1),
    ]:
      check bad.isErr
    let d = defaultLimits()
    check d.maxInFlight == DefaultMaxInFlight and d.maxCalls == DefaultMaxCalls
    check d.maxSubscriptionIds == DefaultMaxSubscriptionIds

suite "trn.evolution: protocol evolution (TRANSPORT §10, §10.1)":
  test "[TRN-0251] unknown fields and kinds are INVALID_PARAMS, then close":
    for v in [
      toCbor(samples()[8]).with("v2", cbor(1'u64)),
      cborMap((cbor(0'u64), cbor(9'u64)), (cbor("id"), cbor(1'u64))),
    ]:
      var (_, callee) = pair()
      check closeCode(callee.receive(wire(v))) == Opt.some(ecInvalidParams)
      var (caller, _) = pair()
      check closeCode(caller.receive(wire(v))) == Opt.some(ecInvalidParams)

  test "[TRN-0254] another hash profile or suite is VERSION_MISMATCH":
    let sent = Hello(module: "storage_module", token: ticketBytes(1), schema: root)
    for (k, v) in [
      ("hash_profile", "logos.hash-profile.2027-01.choice-index"),
      ("hash_suite", "logos.hash-suite.sha-256"),
      ("commitment_model", "logos.commitment-model.2027-01"),
    ]:
      let answer = wire(
        helloMap(
          token = cbor(newSeq[byte]()), schema = schemaCommitment(root).with(k, cbor(v))
        )
      )
      check acceptHelloResponse(sent, answer).error.code == ecVersionMismatch
