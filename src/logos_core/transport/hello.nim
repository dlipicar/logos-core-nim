## TRANSPORT §2.1, §2.3, §3.1, §3.3, §8.1, §8.3, §10.1: the Hello exchange of an
## ordinary protected provider session under the `logos.route-ticket.random-256`
## profile, for the callee (validate, redeem, answer) and the caller (send,
## check the answer), and what each accepts before its part of it is done.
## §8.1.2 (DECISIONS G492): the same exchange for a Runtime-owned
## system-service session, against its own ticket store.

{.push raises: [].}

import results
import logos_sdk/cbor
import ./[envelope, framing, limits, ticket]

export results, envelope, limits, ticket

type
  RouteAccess* = object
    ## [SPEC RUNTIME §9.3 l.3013-3029; TRANSPORT §8.1] The route's scope, as
    ## `route_access` gives it: declaration subtree roots under the selected
    ## contract. none: the whole selected contract (and `logos.schema` for
    ## methods); some(@[]): nothing.
    methods*, publishEvents*, subscribeEvents*: Opt[seq[Digest]]

  RouteBinding* = object
    ## [SPEC TRANSPORT §8.1] What a route ticket binds a session to: the route
    ## constraints the callee checks at the Hello, and the access and decision
    ## it enforces for the session's life.
    consumer*: string
    sourceRuntime*: Opt[string]
      ## a remote consumer's `runtime_instance_id`; none for a local route
    provider*: string ## the selected provider
    contract*: Digest ## the selected contract
    endpoint*: string ## the target endpoint
    route*: string ## the Runtime route
    access*: RouteAccess ## [SPEC TRANSPORT §8.1 l.969-979; CA §11]
    decision*: string
      ## the authority decision id: a correlation value, never a credential
      ## (CAPABILITY-AUTHORITY l.1396)
    expires*: Opt[Nanos]
      ## the route's end on the issuer's monotonic clock (§8.1 l.987); the
      ## owner turns it into the session's end timer at admission
    validUntil*: Opt[int64] ## the decision's `valid_until`, Unix milliseconds (F12)

  CalleeEndpoint* = object ## One connection at an ordinary provider endpoint.
    endpoint*: string
    provider*: string ## the provider served here
    contracts*: seq[Digest]
      ## what it can serve here: its primary contract and implemented interfaces
    sourceRuntime*: Opt[string]
      ## the authenticated source Runtime of a remote connection; none for local

  HelloReason* = enum
    ## Which check failed; for local audit. NOT_AUTHORISED outcomes carry no
    ## reason on the wire (§8.1).
    hrEnvelope ## framing, CBOR, kind, unknown field, or a non-Hello message
    hrModule ## `module` missing or malformed, or (caller) not the name sent
    hrToken ## `token` missing, or (caller) a non-empty response token
    hrSchema ## `schema` missing, malformed, another profile or suite, or differs
    hrTicket ## the route-ticket check
    hrRedeem ## the ticket was consumed concurrently
    hrPeer ## the peer sent a well-formed ProtocolError: close, no reply
    hrSend ## this side's Hello does not fit the peer's frame maximum (§2.1)
    hrState
      ## [E4; DECISIONS I90] the owner's current-state check refused the
      ## binding before redemption (route, realization, consumer)

  HelloFailure* = object
    code*: ErrorCode
    reason*: HelloReason
    peer*: bool ## the peer reported it: close without sending ProtocolError
    msg*: string ## local diagnostic; never the token

  Established* = object
    response*: seq[byte] ## the encoded Hello response to send
    binding*: RouteBinding ## the redeemed route constraints

  SystemPurpose* = enum
    ## [SPEC TRANSPORT l.1068; TRN-0335] What a ticket of the system store is
    ## for: stated in its record, never inferred from the store.
    spNone ## a record no Runtime issued for a system service
    spSystemService

  SystemBinding* = object
    ## [SPEC TRANSPORT §8.1.2 l.1067-1068; TRN-0334; DECISIONS G492] What a
    ## Runtime-owned system-service ticket binds, instead of a module
    ## consumer, a route and a provider-access decision.
    runtime*: string ## the issuing Runtime
    binding*: uint64 ## the system-service binding
    realization*: string ## the exact local provider realization (instance/attempt)
    provider*: string ## the provider served (the Hello's `module`)
    contract*: Digest ## the selected contract
    endpoint*: string ## the exact system-service endpoint
    methods*: seq[Digest] ## the permitted methods' declaration subtree roots
    events*: seq[Digest] ## the permitted events' (none for the Package Manager)
    purpose*: SystemPurpose
      ## The binding's validity is its realization's life, and its revocation
      ## deletes its records (`TicketStore.revoke`): the record's own expiry
      ## is the store's, at most 60 s after issuance (TRN-0336).

  SystemEstablished* = object
    response*: seq[byte] ## the encoded Hello response to send
    binding*: SystemBinding ## the redeemed system-service binding

  SystemHelloCheck* =
    proc(b: SystemBinding): Result[void, HelloFailure] {.gcsafe, raises: [].}
    ## [TRN-0340, TRN-0341] The owner's check that the stored binding is still
    ## the current, authorized one for this session; run before redemption.

  HelloCheck* = proc(b: RouteBinding): Result[void, HelloFailure] {.gcsafe, raises: [].}
    ## [E4; DECISIONS I90] The owner's checks of the current state behind a
    ## valid binding, run after every Hello check and before redemption, so a
    ## refusal consumes nothing (TRANSPORT l.945-946).

const NotAuthorisedMessage* = "not authorised"
  ## [SPEC TRANSPORT §8.1] The one diagnostic for every NOT_AUTHORISED Hello
  ## outcome: it does not reveal which condition occurred.

func failure*(code: ErrorCode, reason: HelloReason, msg: string): HelloFailure =
  HelloFailure(code: code, reason: reason, msg: msg)

func helloFieldCode*(field: string): ErrorCode =
  ## [SPEC TRANSPORT §3.1, §8.3] The outcome of a missing or ill-typed Hello
  ## field, checked in the order module, token, schema.
  case field
  of "token": ecNotAuthorised
  of "schema": ecVersionMismatch
  else: ecInvalidParams

func reasonOf(field: string): HelloReason =
  case field
  of "module": hrModule
  of "token": hrToken
  of "schema": hrSchema
  else: hrEnvelope

type FirstMessage = object
  ## The first message of a connection, when its envelope allows the Hello
  ## checks to run. `schema` is none when that field is missing or malformed:
  ## its VERSION_MISMATCH waits until the module and token checks pass (§3.1).
  message: Message
  schemaOk: bool

proc wipeRefused(m: var Message) =
  ## [DECISIONS G276] A first message that is neither a Hello nor a
  ## ProtocolError is refused before its method is known (§2.3): its payload,
  ## value root and failure text are zeroed, as `decodeMessage` zeroes an
  ## invalid envelope. An Event's data is never marked (INTERFACE §1.2.1).
  case m.kind
  of mkRequest:
    wipe(m.request.params)
    wipe(m.request.commitment)
  of mkResponse:
    if m.response.ok:
      wipe(m.response.resultMap)
      wipe(m.response.commitment)
    else:
      wipe(m.response.failure)
  else:
    discard

proc readFirst(
    frame: openArray[byte], payloadDepth: int
): Result[FirstMessage, HelloFailure] =
  ## Framing, deterministic CBOR, the kind and unknown fields come first; then
  ## the Hello fields in the §3.1 order: module, token, schema (§8.3).
  let v = decodeValue(frame, payloadDepth).valueOr:
    return err(failure(ecInvalidParams, hrEnvelope, $error))
  var m = checkMessage(v)
  if m.isOk:
    # [DECISIONS G276] As `decodeMessage`: the tree around the payload is
    # zeroed once the typed view is taken.
    wipeEnvelope(v)
    if m.value.kind notin {mkHello, mkProtocolError}:
      wipeRefused(m.value)
    return ok(FirstMessage(message: move m.value, schemaOk: true))
  # [DECISIONS G276] An envelope the Hello checks refuse: all of it, as
  # `decodeMessage` does. The partial Hello below holds copies.
  defer:
    wipe(v)
  let e = m.error
  if e.kind != eeField or e.messageKind != Opt.some(mkHello):
    return err(failure(ecInvalidParams, hrEnvelope, $e))
  if e.field != "schema":
    return err(failure(helloFieldCode(e.field), reasonOf(e.field), $e))
  # Fields are checked in order, so module and token passed theirs.
  let partial = Hello(
    module: v.lookup("module").get(cbor("")).getText.get(""),
    token: v.lookup("token").get(cbor(newSeq[byte]())).getBytes.get(@[]),
  )
  ok(FirstMessage(message: Message(kind: mkHello, hello: partial), schemaOk: false))

func peerRefused(m: Message, msg: string): HelloFailure =
  ## [SPEC TRANSPORT §2.3] A well-formed ProtocolError during establishment:
  ## its code is the outcome, and the recipient closes without sending another.
  var f = failure(m.protocolError.code, hrPeer, msg)
  f.peer = true
  f

# Callee ----------------------------------------------------------------------------

proc readHello*(
    frame: openArray[byte], limits = defaultLimits()
): Result[(Hello, bool), HelloFailure] =
  ## [SPEC TRANSPORT §2.3, §3.1] The first message of a connection whose
  ## endpoint judges its Hello itself (remote Runtime Control, G413): the
  ## Hello, and whether its `schema` is well formed (its VERSION_MISMATCH
  ## comes after the module and token checks). A well-formed ProtocolError is
  ## the peer refusing (close, no reply); any other message INVALID_PARAMS.
  let first = ?readFirst(frame, limits.payloadDepth)
  case first.message.kind
  of mkHello:
    ok((first.message.hello, first.schemaOk))
  of mkProtocolError:
    err(peerRefused(first.message, "the caller sent ProtocolError"))
  else:
    err(failure(ecInvalidParams, hrEnvelope, "the first message is not a Hello"))

proc acceptHello*(
    ep: CalleeEndpoint,
    tickets: var TicketStore[RouteBinding],
    frame: openArray[byte],
    now: Nanos,
    limits = defaultLimits(),
    check: HelloCheck = nil,
): Result[Established, HelloFailure] =
  ## [SPEC TRANSPORT §3.1, §8.1, §8.1.1] The callee's Hello checks, in order:
  ## module, token (validated without consuming), schema, the owner's `check`
  ## of the current state (E4), then the atomic redemption. A failure sends ProtocolError with `code` and closes; no
  ## failure consumes a live ticket. Before the Hello, only a Hello or a
  ## well-formed ProtocolError is accepted (§2.3): any other message fails with
  ## INVALID_PARAMS, and a ProtocolError closes the connection with no reply.
  let first = ?readFirst(frame, limits.payloadDepth)
  case first.message.kind
  of mkHello:
    discard
  of mkProtocolError:
    return err(peerRefused(first.message, "the caller sent ProtocolError"))
  else:
    return err(failure(ecInvalidParams, hrEnvelope, "the first message is not a Hello"))
  let h = first.message.hello
  let denied = failure(ecNotAuthorised, hrTicket, NotAuthorisedMessage)
  let b = tickets.validate(h.token, now).valueOr:
    return err(denied)
  # A module other than the ticket's provider, a ticket for another endpoint or
  # provider, a contract this provider does not serve here, or a remote
  # connection from another Runtime: all the same NOT_AUTHORISED (§3.1, §8.1).
  if h.module != b.provider or b.provider != ep.provider or b.endpoint != ep.endpoint or
      b.contract notin ep.contracts or b.sourceRuntime != ep.sourceRuntime:
    return err(denied)
  if not first.schemaOk or h.schema != b.contract:
    return err(
      failure(
        ecVersionMismatch, hrSchema, "the Hello schema is not the selected contract"
      )
    )
  if check != nil:
    ?check(b)
  # [SPEC TRANSPORT §8.1] The response never echoes the ticket; this profile
  # defines no response material, so the token is empty. It is encoded, and
  # checked to fit (§2.1), before the ticket is redeemed; it always fits (a
  # module name, an empty token and a fixed-size schema commitment), and a
  # failure would fail the establishment without consuming the ticket [IMPL].
  let response = encodeMessage(
    Message(
      kind: mkHello, hello: Hello(module: b.provider, token: @[], schema: b.contract)
    ),
    limits.payloadDepth,
    limits.peerFrameLimit,
  ).valueOr:
    return err(failure(ecModule, hrSend, $error))
  let redeemed = tickets.redeem(h.token, now).valueOr:
    return err(failure(ecNotAuthorised, hrRedeem, NotAuthorisedMessage))
  ok(Established(response: response, binding: redeemed))

proc acceptSystemHello*(
    ep: CalleeEndpoint,
    tickets: var TicketStore[SystemBinding],
    frame: openArray[byte],
    now: Nanos,
    limits = defaultLimits(),
    check: SystemHelloCheck = nil,
): Result[SystemEstablished, HelloFailure] =
  ## [SPEC TRANSPORT §8.1.2 l.1072-1077; DECISIONS G492] The system-service
  ## acceptor's Hello: §3.1's order with the system ticket store alone
  ## (TRN-0331, TRN-0332). Invalid, stale, expired, replayed or wrong-purpose
  ## material is NOT_AUTHORISED and no session (TRN-0342); the remaining
  ## checks and their precedence are §3.1's, and the response token is empty
  ## (TRN-0343). The stored binding is validated against the session, module,
  ## contract and current realization (`check`) before redemption (TRN-0340).
  let first = ?readFirst(frame, limits.payloadDepth)
  case first.message.kind
  of mkHello:
    discard
  of mkProtocolError:
    return err(peerRefused(first.message, "the caller sent ProtocolError"))
  else:
    return err(failure(ecInvalidParams, hrEnvelope, "the first message is not a Hello"))
  let h = first.message.hello
  let denied = failure(ecNotAuthorised, hrTicket, NotAuthorisedMessage)
  let b = tickets.validate(h.token, now).valueOr:
    return err(denied)
  if b.purpose != spSystemService or h.module != b.provider or b.provider != ep.provider or
      b.endpoint != ep.endpoint or b.contract notin ep.contracts or
      ep.sourceRuntime.isSome:
    return err(denied)
  if not first.schemaOk or h.schema != b.contract:
    return err(
      failure(
        ecVersionMismatch, hrSchema, "the Hello schema is not the binding's contract"
      )
    )
  if check != nil:
    ?check(b)
  let response = encodeMessage(
    Message(
      kind: mkHello, hello: Hello(module: b.provider, token: @[], schema: b.contract)
    ),
    limits.payloadDepth,
    limits.peerFrameLimit,
  ).valueOr:
    return err(failure(ecModule, hrSend, $error))
  let redeemed = tickets.redeem(h.token, now).valueOr:
    return err(failure(ecNotAuthorised, hrRedeem, NotAuthorisedMessage))
  ok(SystemEstablished(response: response, binding: redeemed))

# Caller ----------------------------------------------------------------------------

proc helloRequest*(
    module: string,
    ticket: openArray[byte],
    contract: Digest,
    peerLimit: uint32 = MinFrameLimit,
): Result[seq[byte], EnvelopeError] =
  ## [SPEC TRANSPORT §2.1, §3.1, §8.1] The caller's Hello: the selected
  ## provider, the one-time ticket, and the selected contract. A Hello that does
  ## not fit the peer's frame maximum (16 MiB before any is established) fails
  ## with `eeTooLarge`, and so does the establishment.
  encodeMessage(
    Message(
      kind: mkHello, hello: Hello(module: module, token: @ticket, schema: contract)
    ),
    peerLimit = peerLimit,
  )

proc acceptHelloResponse*(
    sent: Hello, frame: openArray[byte], limits = defaultLimits()
): Result[void, HelloFailure] =
  ## [SPEC TRANSPORT §3.1, §10.1] After envelope validation, the callee's answer
  ## in the order module, token, schema: the same module (INVALID_PARAMS), the
  ## empty token this profile requires (NOT_AUTHORISED), the same contract
  ## (VERSION_MISMATCH). A well-formed ProtocolError is the callee refusing the
  ## Hello: its code is the outcome, and nothing is sent back (§2.3; RUNTIME §4.1
  ## passes it through). Any other message is INVALID_PARAMS (§2.3).
  let first = ?readFirst(frame, limits.payloadDepth)
  let m = first.message
  case m.kind
  of mkHello:
    let h = m.hello
    if h.module != sent.module:
      return
        err(failure(ecInvalidParams, hrModule, "the response names another module"))
    if h.token.len != 0:
      return err(failure(ecNotAuthorised, hrToken, "the response token is not empty"))
    if not first.schemaOk or h.schema != sent.schema:
      return
        err(failure(ecVersionMismatch, hrSchema, "the response names another contract"))
    ok()
  of mkProtocolError:
    err(peerRefused(m, "the callee refused the Hello"))
  else:
    err(failure(ecInvalidParams, hrEnvelope, "the first answer is not a Hello"))
