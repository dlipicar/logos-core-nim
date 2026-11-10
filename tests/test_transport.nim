## TRANSPORT (Tier 3, sans-I/O): the envelope codec, framing, deterministic CBOR,
## the Hello exchange and route tickets, requests, cancellation, multiplexing,
## subscriptions and protocol evolution, with the evil-peer cases of G30-G37.

import std/[sequtils, strutils]
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
  encodeMessage(
    Message(
      kind: mkRequest,
      request: Request(id: id, methodName: methodName, params: p, commitment: c),
    )
  ).get

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
    # whatever they hold.
    let odd = cborMap(
      (cbor("cid"), cborTag(42, cbor(1'u64))),
      (cbor("x"), cborArray(cborNull(), cborFloatBits(fw16, 0x3e00))),
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

suite "trn.direction: who sends what (TRANSPORT §1.2, §1.4)":
  test "[IMPL-DECISION G30] the callee closes on caller-bound kinds":
    for m in samples():
      if m.kind notin {mkResponse, mkEvent, mkSubscriptionResult}:
        continue
      var (_, callee) = pair()
      let acts = callee.receive(encodeMessage(m).get)
      check closeCode(acts) == Opt.some(ecInvalidParams)
      check callee.state == csClosed
      check dispatched(acts).len == 0

  test "[IMPL-DECISION G30] the caller closes on callee-bound kinds":
    for m in samples():
      if m.kind notin {mkRequest, mkSubscribe, mkUnsubscribe, mkCancel}:
        continue
      var (caller, _) = pair()
      check closeCode(caller.receive(encodeMessage(m).get)) == Opt.some(ecInvalidParams)
      check caller.state == csClosed

  test "a ProtocolError from the peer closes without a reply":
    var (caller, callee) = pair()
    let pe = encodeMessage(samples()[7]).get
    let acts = callee.receive(pe)
    check acts.len == 1 and acts[0].kind == caClose and acts[0].close.send.isNone
    discard caller.request("exists", params()).get
    let evs = caller.receive(pe)
    check evs[0].kind == ceResponse and evs[0].outcome.failure.code == ecTransport
    check evs[^1].kind == ceClose and evs[^1].close.send.isNone

suite "trn.framing: stream framing (TRANSPORT §2.1, §8.3)":
  test "[TRN-0051] [TRN-0052] a frame is a 4-byte big-endian length and the body":
    check frame([1'u8, 2, 3]).get == @[0'u8, 0, 0, 3, 1, 2, 3]
    check frame(newSeq[byte](0x0102)).get[0 .. 3] == @[0'u8, 0, 1, 2]
    var r = newFrameReader(1000)
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
    var r2 = newFrameReader(1000)
    check r2.feed(stream & frame([]).get).get.len == samples().len + 1

  test "[TRN-0053] [TRN-0054] [TRN-0055] [TRN-0199] a length over the limit fails before the body is read or allocated":
    var r = newFrameReader(100)
    check r.feed([0'u8, 0, 0, 100]).get.len == 0
    check r.buffered == 0
    var r2 = newFrameReader(100)
    let e = r2.feed([0'u8, 0, 0, 101, 1, 2, 3]).error
    check e.kind == feTooLarge and e.declared == 101
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

  test "[TRN-0056] the default limit is the 16 MiB floor the spec pins":
    let pinned = pin("trn-max-frame-floor")
    check pinned == "16 MiB"
    check MinFrameLimit == parseInt(pinned.split(' ')[0]) * 1024 * 1024
    var r = newFrameReader()
    check r.limit == uint32(MinFrameLimit)
    let n = uint32(MinFrameLimit)
    check r.feed([byte(n shr 24), byte(n shr 16), byte(n shr 8), byte(n)]).isOk
    check r.feed(newSeq[byte](MinFrameLimit)).get.len == 1

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
    check frame(encodeMessage(m).get).get.len < MinFrameLimit

  test "a stream that ends inside a frame is truncated":
    var r = newFrameReader(100)
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

  test "[IMPL-DECISION G59] nesting past the decoder cap is malformed, without detail":
    var deep = cbor(1'u64)
    for _ in 0 .. DefaultMaxDepth + 1:
      deep = cborArray(deep)
    let b = wire(toCbor(samples()[1]).with("params", cborMap((cbor("cid"), deep))))
    check decodeMessage(b).error.kind == eeMalformed
    var (_, callee) = pair()
    check closeCode(callee.receive(b)) == Opt.some(ecInvalidParams)

  test "[IMPL-DECISION G38] floats and invalid UTF-8 inside payloads pass the envelope and fail at the schema":
    let invalidText = CborValue(kind: ckText, text: "\xff", validUtf8: false)
    for x in [
      cborFloatBits(fw16, 0x3e00), invalidText, cborTag(1, cbor(1'u64)), cborNull()
    ]:
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

  test "[TRN-0072] a missing or malformed module is INVALID_PARAMS and consumes nothing; another module is NOT_AUTHORISED":
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

  test "[TRN-0073] [TRN-0144] [TRN-0155] [TRN-0156] a missing, empty, malformed or unknown token is NOT_AUTHORISED and consumes nothing":
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

  test "[TRN-0074] [TRN-0071] [TRN-0254] a schema that differs or is malformed is VERSION_MISMATCH, after the token check":
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

  test "[TRN-0146] [TRN-0145] [TRN-0157] [TRN-0177] [TRN-0079] a redeemed ticket never establishes another session":
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

  test "[TRN-0076] [TRN-0070] the caller checks the module, token and schema of the answer":
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
    # [IMPL-DECISION G33] A response token is NOT_AUTHORISED.
    check acceptHelloResponse(sent, answer(token = @[1'u8])).error.code ==
      ecNotAuthorised
    # [IMPL-DECISION G34] The callee's ProtocolError is the outcome.
    let refused = encodeMessage(
      Message(
        kind: mkProtocolError, protocolError: InvocationFailure(code: ecVersionMismatch)
      )
    ).get
    let f = acceptHelloResponse(sent, refused).error
    check f.code == ecVersionMismatch and f.peer
    check acceptHelloResponse(sent, encodeMessage(samples()[8]).get).error.code ==
      ecInvalidParams

  test "[IMPL-DECISION G30] a first message that is not a Hello is INVALID_PARAMS":
    var store: TicketStore[RouteBinding]
    discard store.issue(routeBinding(), 0, 100 * Second).get
    let f = acceptHello(endpoint, store, requestFor(0), Second).error
    check f.code == ecInvalidParams
    check store.len == 1

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
  test "[IFC-0426] [TRN-0085] [TRN-0089] [TRN-0090] [TRN-0091] [TRN-0092] [TRN-0093] [TRN-0094] a call round trip carries recomputable commitments":
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

  test "[TRN-0095] [TRN-0096] [TRN-0097] a commitment that does not match closes the session":
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

  test "[IMPL-DECISION G37] the subtree root is checked before the schema; a schema-invalid request then fails the call":
    let bad = cborMap((cbor("cid"), cbor(5'u64)))
    var (_, callee) = pair()
    let acts = callee.receive(
      rawRequest(
        0,
        "exists",
        bad,
        PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_request")),
      )
    )
    check callee.state == csOpen
    let resp = sent(acts)[0].response
    check not resp.ok and resp.failure.code == ecInvalidParams
    check resp.failure.detail.isSome
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

  test "[IMPL-DECISION G36] a schema-invalid response-ok closes; the call gets TRANSPORT_ERROR":
    var (caller, _) = pair()
    let (id, _) = caller.request("exists", params()).get
    let bad = cborMap((cbor("exists"), cbor(5'u64)))
    let resp = encodeMessage(
      Message(
        kind: mkResponse,
        response: Response(
          id: id,
          ok: true,
          resultMap: bad,
          commitment:
            PayloadCommitment(subtreeRoot: subtreeOf("storage.exists_response")),
        ),
      )
    ).get
    let evs = caller.receive(resp)
    check evs[0].id == id and evs[0].outcome.failure.code == ecTransport
    check closeCode(evs) == Opt.some(ecInvalidParams)

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
    let garbage = cborMap((cbor("x"), cborFloatBits(fw16, 0x3e00)))
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
  test "[TRN-0130] [TRN-0131] a Cancel before the terminal Response commits exactly one CANCELLED":
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

  test "[IMPL-DECISION G31] replies to abandoned calls are dropped; uncorrelated ones close":
    var (caller, callee) = pair()
    let (id, req) = caller.request("exists", params()).get
    discard callee.receive(req)
    check caller.abandon(id)
    check caller.receive(callee.respond(id, okExists()).get).len == 0
    check caller.state == csOpen
    let stray = encodeMessage(samples()[2]).get
    check closeCode(caller.receive(stray)) == Opt.some(ecInvalidParams)

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
  test "[TRN-0106] [TRN-0109] [TRN-0114] [TRN-0115] [TRN-0116] Subscribe, events, Unsubscribe":
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

  test "[TRN-0107] [TRN-0108] the caller keeps one control operation per id":
    var (caller, _) = pair()
    discard caller.subscribe(1, "storage.started_event").get
    check caller.unsubscribe(1).isErr
    check caller.subscribe(1, "storage.started_event").isErr
    check caller.subscribe(2, "metrics.nope").isErr

  test "[TRN-0110] [TRN-0113] an event outside the selected contract fails with NOT_AUTHORISED; failures change nothing":
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
    proc subscribeTo(id: uint64, event: string): seq[byte] =
      encodeMessage(
        Message(kind: mkSubscribe, subscribe: Subscribe(id: id, event: event))
      ).get

    let r = sent(callee.receive(subscribeTo(1, "watcher.alarm_event")))[0]
    check r.subscriptionResult.id == 1
    check r.subscriptionResult.operation == mkSubscribe
    check r.subscriptionResult.failure.get.code == ecNotAuthorised
    # Nothing was registered: id 1 can still subscribe to a selected event.
    check callee.receive(subscribeTo(1, "watch.tick_event"))[0].kind == caSubscribe
    # A failed result leaves the state as it was: still not active.
    check callee.subscriptionResult(
      1, Opt.some(InvocationFailure(code: ecNotAuthorised))
    ).isSome
    check callee.publish(1, cborMap((cbor("n"), cbor(1'u64)))).isErr

  test "[IMPL-DECISION G32] reused, unknown and overlapping ids fail with INVALID_PARAMS":
    var (caller, callee) = pair()
    discard callee.receive(caller.subscribe(1, "storage.started_event").get)
    let again = encodeMessage(
      Message(
        kind: mkSubscribe, subscribe: Subscribe(id: 1, event: "storage.started_event")
      )
    ).get
    check sent(callee.receive(again))[0].subscriptionResult.failure.get.code ==
      ecInvalidParams
    let overlap =
      encodeMessage(Message(kind: mkUnsubscribe, unsubscribe: Unsubscribe(id: 1))).get
    check sent(callee.receive(overlap))[0].subscriptionResult.failure.get.code ==
      ecInvalidParams
    let unknown =
      encodeMessage(Message(kind: mkUnsubscribe, unsubscribe: Unsubscribe(id: 9))).get
    check sent(callee.receive(unknown))[0].subscriptionResult.failure.get.code ==
      ecInvalidParams
    check callee.subscriptionResult(1).isSome

  test "[IMPL-DECISION G31] an Event or SubscriptionResult with nothing to match closes":
    var (caller, _) = pair()
    check closeCode(caller.receive(encodeMessage(samples()[6]).get)) ==
      Opt.some(ecInvalidParams)
    var (caller2, _) = pair()
    check closeCode(caller2.receive(encodeMessage(samples()[9]).get)) ==
      Opt.some(ecInvalidParams)

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
