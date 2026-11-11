## TRANSPORT §1, §2.3, §8.3, §10: the nine message kinds as typed values, a
## strict decoder, and an encoder that checks what it emits against the same
## rules.
##
## The rules come from the mirrored §1.1 and §1.3 CDDL (`protocddl.nim`): the
## kind of each message, its closed field set, and every field type. The Nim
## types below are a view of those rules; loading this module checks that the
## view and the pinned CDDL agree, so a spec revision that changes a kind or the
## union fails here before any message is read.
##
## Logos deterministic CBOR (INTERFACE §4.4) covers the whole message, the
## payload maps included: a floating-point item anywhere, or `params`, `result`
## or `data` nested deeper than the payload-depth limit P, fails the envelope
## (§2.3; INTERFACE §4.5, §4.5.1).

{.push raises: [].}

import results
import ../cbor
import ../commitment
import ../hash/hashinput
import ../iface/[outcome, surface]
import ../pins
import ./[framing, protocddl]

export results, outcome, hashinput

type
  MessageKind* = enum
    ## [SPEC TRANSPORT §1.1, §1.2] `logos.transport.message-kind`.
    mkHello = 0
    mkRequest = 1
    mkResponse = 2
    mkSubscribe = 3
    mkUnsubscribe = 4
    mkEvent = 5
    mkProtocolError = 6
    mkCancel = 7
    mkSubscriptionResult = 8

  PayloadCommitment* = object ## [SPEC TRANSPORT §1.3, §4.1]
    subtreeRoot*: Digest ## `schema_subtree_root`
    valueRoot*: Digest ## `value_root`

  Hello* = object
    module*: string
    token*: seq[byte]
    schema*: Digest ## the `schema_root` of its `logos.schema_commitment`

  Request* = object
    id*: uint64
    methodName*: string ## the bare method name
    params*: CborValue ## an opaque map until the schema-aware boundary
    commitment*: PayloadCommitment

  Response* = object
    id*: uint64
    case ok*: bool
    of true:
      resultMap*: CborValue ## `result`
      commitment*: PayloadCommitment
    of false:
      failure*: InvocationFailure ## `error`

  Subscribe* = object
    id*: uint64
    event*: string

  Unsubscribe* = object
    id*: uint64

  SubscriptionResult* = object
    id*: uint64
    operation*: MessageKind ## mkSubscribe or mkUnsubscribe
    failure*: Opt[InvocationFailure] ## `error`, on a failed operation

  Event* = object
    sub*: uint64
    event*: string
    data*: CborValue
    commitment*: PayloadCommitment

  Cancel* = object
    id*: uint64

  Message* = object
    case kind*: MessageKind
    of mkHello:
      hello*: Hello
    of mkRequest:
      request*: Request
    of mkResponse:
      response*: Response
    of mkSubscribe:
      subscribe*: Subscribe
    of mkUnsubscribe:
      unsubscribe*: Unsubscribe
    of mkEvent:
      event*: Event
    of mkProtocolError:
      protocolError*: InvocationFailure
    of mkCancel:
      cancel*: Cancel
    of mkSubscriptionResult:
      subscriptionResult*: SubscriptionResult

  EnvelopeErrorKind* = enum
    eeMalformed ## not one well-formed CBOR item
    eeNonDeterministic
      ## not Logos deterministic CBOR (INTERFACE §4.4), a float anywhere included
    eeTooDeep
      ## nested deeper than the payload-depth limit plus the envelope's one
      ## level (§2.3, INTERFACE §4.5.1), or tags past the decoder's tag bound
    eeNotMap ## the message is not a map
    eeFirstKey ## the first entry is not key 0 (§1)
    eeUnknownKind ## not an allocated message-kind value (§8.3, §10)
    eeUnknownField ## a field the kind does not define (§1.3, §10)
    eeField ## a required field is missing, or a field has the wrong type
    eeForm ## no form of a choice message matches (response, subscription result)
    eeRule ## a rule outside the CDDL: nonzero codes, detail (§1.3)
    eeTooLarge
      ## sending only: the body does not fit the peer-supported frame maximum (§2.1)

  EnvelopeError* = object
    kind*: EnvelopeErrorKind
    messageKind*: Opt[MessageKind]
    field*: string ## the failing top-level field, when one is to blame
    msg*: string

const KindRule*: array[MessageKind, string] = [
  ## [SPEC TRANSPORT §1.2, §1.3] The rule each kind's messages follow.
  "logos.transport.hello", "logos.transport.request", "logos.transport.response",
  "logos.transport.subscribe", "logos.transport.unsubscribe", "logos.transport.event",
  "logos.transport.protocol-error", "logos.transport.cancel",
  "logos.transport.subscription-result",
]

type Envelope = object
  schema: ProtocolSchema
  kindRange: PType ## `logos.transport.message-kind`
  arms: array[MessageKind, seq[PType]] ## the closed maps each kind allows

proc loadEnvelope(): Result[Envelope, string] =
  let s = ?loadProtocolSchema(
    [TransportPrimitivesDocument, TransportEnvelopesDocument],
    pinnedContext().commonModel,
  )
  var e = Envelope(schema: s)
  e.kindRange = s.rule("logos.transport.message-kind").valueOr:
    return err("no logos.transport.message-kind")
  let union = s.rule("logos.transport.message").valueOr:
    return err("no logos.transport.message")
  if union.kind != pkChoice:
    return err("logos.transport.message is not a choice")
  var seen: set[MessageKind]
  for arm in union.arms:
    if arm.kind != pkRef:
      return err("a message-union arm is not a rule name")
    let maps = s.mapArms(arm)
    if maps.len == 0:
      return err(arm.name & " is not a map or a choice of maps")
    var kind = -1'i64
    for m in maps:
      let k0 = m.member(cbor(0'u64)).valueOr:
        return err(arm.name & " has no key 0")
      let k = s.intValue(k0.typ).valueOr:
        return err(arm.name & " key 0 is not a kind literal")
      if kind >= 0 and k != kind:
        return err(arm.name & " forms disagree on the kind")
      kind = k
    if kind < 0 or kind > int64(high(MessageKind)) or
        not s.matches(e.kindRange, cbor(kind)):
      return err(arm.name & " has kind " & $kind & ", outside MessageKind")
    let mk = MessageKind(kind)
    if KindRule[mk] != arm.name:
      return err("kind " & $kind & " is " & arm.name & ", not " & KindRule[mk])
    if mk in seen:
      return err("kind " & $kind & " is allocated twice")
    seen.incl(mk)
    e.arms[mk] = maps
  for mk in MessageKind:
    if mk notin seen:
      return err("kind " & $mk.ord & " has no message in the union")
  for n in [-1'i64, int64(high(MessageKind)) + 1]:
    if s.matches(e.kindRange, cbor(n)):
      return err("logos.transport.message-kind allows " & $n)
  ok(e)

let envelope = block:
  let e = loadEnvelope()
  doAssert e.isOk,
    "the pinned TRANSPORT §1 CDDL does not match the envelope types: " & e.error &
      ": re-derive transport/envelope.nim from the spec revision"
  e.get

func envelopeSchema*(): ProtocolSchema =
  {.cast(noSideEffect).}:
    envelope.schema

func kindRangeRule(): PType =
  {.cast(noSideEffect).}:
    envelope.kindRange

func messageArms*(k: MessageKind): seq[PType] =
  ## The closed maps a message of kind `k` may be.
  {.cast(noSideEffect).}:
    envelope.arms[k]

# Checking --------------------------------------------------------------------------

func fail(
    kind: EnvelopeErrorKind, msg: string, mk = Opt.none(MessageKind), field = ""
): EnvelopeError =
  EnvelopeError(kind: kind, messageKind: mk, field: field, msg: msg)

func `$`*(e: EnvelopeError): string =
  var s = $e.kind
  if e.messageKind.isSome:
    s.add(" in " & KindRule[e.messageKind.get])
  if e.field.len > 0:
    s.add(" field " & e.field)
  s & ": " & e.msg

func keyName(k: CborValue): string =
  case k.kind
  of ckText:
    k.text
  of ckUint:
    $k.uint
  else:
    "a non-text key"

func checkFields(v: CborValue): Result[MessageKind, EnvelopeError] =
  ## [SPEC TRANSPORT §1, §1.3, §2.3, §8.3, §10] The envelope of one decoded
  ## message: a map whose first entry is key 0, an allocated kind, no field the
  ## kind does not define, then each field in CDDL order (for Hello the order
  ## of §3.1), then the form of a choice message.
  let s = envelopeSchema()
  if v.isNil or v.kind != ckMap:
    return err(fail(eeNotMap, "a message is a map"))
  if v.entries.len == 0 or v.entries[0].key.kind != ckUint or v.entries[0].key.uint != 0:
    return err(fail(eeFirstKey, "the first map entry is not key 0"))
  let kv = v.entries[0].value
  if not s.matches(kindRangeRule(), kv):
    return err(fail(eeUnknownKind, "not an allocated message kind"))
  let mk = MessageKind(kv.uint)
  let arms = messageArms(mk)
  for (k, _) in v.entries:
    var known = false
    for a in arms:
      if a.member(k).isSome:
        known = true
    if not known:
      return err(fail(eeUnknownField, "unknown field", Opt.some(mk), keyName(k)))
  if arms.len == 1:
    for m in arms[0].members:
      if m.key.isInt:
        continue # key 0, the kind
      var x: CborValue = nil
      for (k, val) in v.entries:
        if k.kind == ckText and k.text == m.key.textKey:
          x = val
      if x.isNil:
        if not m.optional:
          return err(fail(eeField, "missing", Opt.some(mk), m.key.textKey))
      elif not s.matches(m.typ, x):
        return err(fail(eeField, "wrong type", Opt.some(mk), m.key.textKey))
  else:
    var any = false
    for a in arms:
      if s.matches(a, v):
        any = true
    if not any:
      return err(fail(eeForm, "matches no form of the message", Opt.some(mk)))
  ok(mk)

# Typed views -----------------------------------------------------------------------

func get(v: CborValue, key: string): CborValue =
  v.lookup(key).get(nil)

func digestOf(v: CborValue): Digest =
  toDigest(v).get(default(Digest))

func commitmentOf(v: CborValue): PayloadCommitment =
  PayloadCommitment(
    subtreeRoot: digestOf(v.get("schema_subtree_root")),
    valueRoot: digestOf(v.get("value_root")),
  )

proc failureOf(
    v: CborValue, mk: MessageKind, field: string
): Result[InvocationFailure, EnvelopeError] =
  ## An `error-payload` or `protocol-error`: its code nonzero (§1.3), and its
  ## detail valid for that code (INTERFACE §5.1).
  let code = parseErrorCode(v.get("code")).valueOr:
    return err(fail(eeField, error, Opt.some(mk), field))
  var f = InvocationFailure(code: code)
  let m = v.lookup("message")
  if m.isSome:
    f.message = Opt.some(m.get.text)
  let d = v.lookup("detail")
  if d.isSome:
    f.detail = Opt.some(d.get.bytes)
  checkFailure(f).isOkOr:
    return err(fail(eeRule, error, Opt.some(mk), field))
  ok(f)

proc typed(v: CborValue, mk: MessageKind): Result[Message, EnvelopeError] =
  case mk
  of mkHello:
    let root = parseSchemaCommitment(v.get("schema")).valueOr:
      return err(fail(eeField, error, Opt.some(mk), "schema"))
    ok(
      Message(
        kind: mkHello,
        hello:
          Hello(module: v.get("module").text, token: v.get("token").bytes, schema: root),
      )
    )
  of mkRequest:
    ok(
      Message(
        kind: mkRequest,
        request: Request(
          id: v.get("id").uint,
          methodName: v.get("method").text,
          params: v.get("params"),
          commitment: commitmentOf(v.get("commitment")),
        ),
      )
    )
  of mkResponse:
    let id = v.get("id").uint
    if v.lookup("error").isSome:
      let f = ?failureOf(v.get("error"), mk, "error")
      ok(Message(kind: mkResponse, response: Response(id: id, ok: false, failure: f)))
    else:
      ok(
        Message(
          kind: mkResponse,
          response: Response(
            id: id,
            ok: true,
            resultMap: v.get("result"),
            commitment: commitmentOf(v.get("commitment")),
          ),
        )
      )
  of mkSubscribe:
    ok(
      Message(
        kind: mkSubscribe,
        subscribe: Subscribe(id: v.get("id").uint, event: v.get("event").text),
      )
    )
  of mkUnsubscribe:
    ok(Message(kind: mkUnsubscribe, unsubscribe: Unsubscribe(id: v.get("id").uint)))
  of mkEvent:
    ok(
      Message(
        kind: mkEvent,
        event: Event(
          sub: v.get("sub").uint,
          event: v.get("event").text,
          data: v.get("data"),
          commitment: commitmentOf(v.get("commitment")),
        ),
      )
    )
  of mkProtocolError:
    ok(Message(kind: mkProtocolError, protocolError: ?failureOf(v, mk, "code")))
  of mkCancel:
    ok(Message(kind: mkCancel, cancel: Cancel(id: v.get("id").uint)))
  of mkSubscriptionResult:
    var r = SubscriptionResult(
      id: v.get("id").uint, operation: MessageKind(v.get("operation").uint)
    )
    if v.lookup("error").isSome:
      r.failure = Opt.some(?failureOf(v.get("error"), mk, "error"))
    ok(Message(kind: mkSubscriptionResult, subscriptionResult: r))

proc checkMessage*(v: CborValue): Result[Message, EnvelopeError] =
  ## [SPEC TRANSPORT §1.3, §2.3, §8.3] A decoded message as its typed view, or
  ## the first envelope check it fails.
  let mk = ?checkFields(v)
  typed(v, mk)

func decodeValue*(
    data: openArray[byte], payloadDepth = DefaultMaxDepth
): Result[CborValue, EnvelopeError] =
  ## [SPEC TRANSPORT §2.3, §8.3] One frame body as one Logos deterministic-CBOR
  ## item (INTERFACE §4.4): no floating-point item at any depth, the payload maps
  ## included (INTERFACE §4.5). The whole message nests at most
  ## `payloadDepth + 1` arrays and maps: the envelope map adds exactly one level
  ## above `params`, `result` and `data`, and its other fields nest two at most,
  ## so this is the payload-depth check of INTERFACE §4.5.1, made before any
  ## container beyond it is allocated. `payloadDepth` is P, at least 128
  ## (`TransportLimits`). Text inside the payload maps may be invalid UTF-8: like
  ## a tag or null there, that is a schema mismatch at the schema-aware boundary
  ## (INTERFACE §4.5), as in direct mode [IMPL].
  var opts = defaultDecodeOptions()
  opts.allowInvalidUtf8 = true
  opts.maxDepth = payloadDepth + 1
  let v = decodeCbor(data, opts).valueOr:
    return err(
      case error.kind
      of cekNonDeterministic:
        fail(eeNonDeterministic, $error)
      of cekTooDeep:
        fail(eeTooDeep, $error)
      of cekMalformed, cekInvalidUtf8:
        fail(eeMalformed, $error)
    )
  ok(v)

proc decodeMessage*(
    data: openArray[byte], payloadDepth = DefaultMaxDepth
): Result[Message, EnvelopeError] =
  ## [SPEC TRANSPORT §2.3, §8.3] One frame body whose envelope is valid.
  checkMessage(?decodeValue(data, payloadDepth))

func checkPayload*(v: CborValue, payloadDepth: int): Result[void, EnvelopeError] =
  ## [SPEC TRANSPORT §2.3; INTERFACE §4.4 item 5, §4.5.1] What a receiver's
  ## envelope check asks of a `params`, `result` or `data` value about to be sent:
  ## no floating-point item, and at most `payloadDepth` arrays and maps on any
  ## path (the root map is depth one; tags and scalars add none). Iterative.
  var stack: seq[(CborValue, int)] = @[(v, 1)]
  while stack.len > 0:
    let (x, depth) = stack.pop()
    if x.isNil:
      continue
    case x.kind
    of ckArray, ckMap:
      if depth > payloadDepth:
        return err(fail(eeTooDeep, "the payload nests deeper than " & $payloadDepth))
      if x.kind == ckArray:
        for item in x.items:
          stack.add((item, depth + 1))
      else:
        for (k, val) in x.entries:
          stack.add((k, depth + 1))
          stack.add((val, depth + 1))
    of ckTag:
      stack.add((x.content, depth))
    of ckFloat:
      return err(fail(eeNonDeterministic, "a floating-point item in the payload"))
    else:
      discard
  ok()

func peekKind*(data: openArray[byte]): Opt[uint64] =
  ## [SPEC TRANSPORT §1] The kind from the map header and the first entry alone.
  ## Selects nothing by itself: `decodeMessage` still checks the whole message.
  if data.len < 3 or (data[0] shr 5) != 5 or (data[0] and 0x1f) >= 28:
    return Opt.none(uint64)
  let head = [1, 2, 3, 5, 9]
  let info = int(data[0] and 0x1f)
  let skip =
    if info < 24:
      1
    else:
      head[info - 23]
  if data.len < skip + 2 or data[skip] != 0x00:
    return Opt.none(uint64)
  let k = data[skip + 1]
  if k < 24:
    Opt.some(uint64(k))
  elif k == 24 and data.len > skip + 2:
    Opt.some(uint64(data[skip + 2]))
  else:
    Opt.none(uint64)

# Encoding --------------------------------------------------------------------------

func entry(key: string, v: CborValue): CborEntry =
  (cbor(key), v)

func toCbor*(c: PayloadCommitment): CborValue =
  cborMap(
    entry("schema_subtree_root", cbor(c.subtreeRoot)),
    entry("value_root", cbor(c.valueRoot)),
  )

func failureEntries(f: InvocationFailure): seq[CborEntry] =
  var e = @[entry("code", cbor(uint64(f.code.ord)))]
  if f.message.isSome:
    e.add(entry("message", cbor(f.message.get)))
  if f.detail.isSome:
    e.add(entry("detail", cbor(f.detail.get)))
  e

func toCbor*(m: Message): CborValue =
  var e: seq[CborEntry] = @[(cbor(0'u64), cbor(uint64(m.kind.ord)))]
  case m.kind
  of mkHello:
    e.add(entry("module", cbor(m.hello.module)))
    e.add(entry("token", cbor(m.hello.token)))
    e.add(entry("schema", schemaCommitment(m.hello.schema)))
  of mkRequest:
    e.add(entry("id", cbor(m.request.id)))
    e.add(entry("method", cbor(m.request.methodName)))
    e.add(entry("params", m.request.params))
    e.add(entry("commitment", toCbor(m.request.commitment)))
  of mkResponse:
    e.add(entry("id", cbor(m.response.id)))
    if m.response.ok:
      e.add(entry("result", m.response.resultMap))
      e.add(entry("commitment", toCbor(m.response.commitment)))
    else:
      e.add(entry("error", cborMap(failureEntries(m.response.failure))))
  of mkSubscribe:
    e.add(entry("id", cbor(m.subscribe.id)))
    e.add(entry("event", cbor(m.subscribe.event)))
  of mkUnsubscribe:
    e.add(entry("id", cbor(m.unsubscribe.id)))
  of mkEvent:
    e.add(entry("sub", cbor(m.event.sub)))
    e.add(entry("event", cbor(m.event.event)))
    e.add(entry("data", m.event.data))
    e.add(entry("commitment", toCbor(m.event.commitment)))
  of mkProtocolError:
    e.add(failureEntries(m.protocolError))
  of mkCancel:
    e.add(entry("id", cbor(m.cancel.id)))
  of mkSubscriptionResult:
    let r = m.subscriptionResult
    e.add(entry("id", cbor(r.id)))
    e.add(entry("operation", cbor(uint64(r.operation.ord))))
    if r.failure.isSome:
      e.add(entry("error", cborMap(failureEntries(r.failure.get))))
  cborMap(e)

func payloadOf(m: Message): CborValue =
  case m.kind
  of mkRequest:
    m.request.params
  of mkResponse:
    if m.response.ok: m.response.resultMap else: nil
  of mkEvent:
    m.event.data
  else:
    nil

proc encodeMessage*(
    m: Message, payloadDepth = DefaultMaxDepth, peerLimit: uint32 = MinFrameLimit
): Result[seq[byte], EnvelopeError] =
  ## [SPEC TRANSPORT §2.1, §2.3] The Logos deterministic-CBOR encoding of `m`,
  ## after the receive-side envelope checks pass on it [IMPL]: no invalid
  ## envelope is sent. The body must fit the peer-supported maximum.
  let v = toCbor(m)
  discard ?checkMessage(v)
  let p = payloadOf(m)
  if not p.isNil:
    ?checkPayload(p, payloadDepth)
  let bytes = encodeCbor(v)
  if not fits(bytes.len, peerLimit):
    return err(
      fail(
        eeTooLarge,
        "a body of " & $bytes.len & " bytes over the peer's " & $peerLimit,
        Opt.some(m.kind),
      )
    )
  ok(bytes)
