## TRANSPORT §3.1, §3.3, §8.1, §8.3, §10.1: the Hello exchange of an ordinary
## protected provider session under the `logos.route-ticket.random-256`
## profile, for the callee (validate, redeem, answer) and the caller (send,
## check the answer).

{.push raises: [].}

import results
import ../cbor
import ./[envelope, ticket]

export results, envelope, ticket

type
  RouteBinding* = object
    ## [SPEC TRANSPORT §8.1] What a route ticket binds a session to, as far as
    ## the transport can check it. The Runtime (tier 4) adds the route access
    ## and the authority decision, and enforces them after redemption.
    consumer*: string
    sourceRuntime*: Opt[string]
      ## a remote consumer's `runtime_instance_id`; none for a local route
    provider*: string ## the selected provider
    contract*: Digest ## the selected contract
    endpoint*: string ## the target endpoint
    route*: string ## the Runtime route

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
    hrPeer ## the peer answered with ProtocolError

  HelloFailure* = object
    code*: ErrorCode
    reason*: HelloReason
    peer*: bool ## the peer reported it: close without sending ProtocolError
    msg*: string ## local diagnostic; never the token

  Established* = object
    response*: seq[byte] ## the encoded Hello response to send
    binding*: RouteBinding ## the redeemed route constraints

const NotAuthorisedMessage* = "not authorised"
  ## [SPEC TRANSPORT §8.1] The one diagnostic for every NOT_AUTHORISED Hello
  ## outcome: it does not reveal which condition occurred.

func failure(code: ErrorCode, reason: HelloReason, msg: string): HelloFailure =
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

proc readFirst(frame: openArray[byte]): Result[FirstMessage, HelloFailure] =
  ## Framing, deterministic CBOR, the kind and unknown fields come first; then
  ## the Hello fields in the §3.1 order: module, token, schema (§8.3).
  let v = decodeValue(frame).valueOr:
    return err(failure(ecInvalidParams, hrEnvelope, $error))
  let m = checkMessage(v)
  if m.isOk:
    return ok(FirstMessage(message: m.get, schemaOk: true))
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

# Callee ----------------------------------------------------------------------------

proc acceptHello*(
    ep: CalleeEndpoint,
    tickets: var TicketStore[RouteBinding],
    frame: openArray[byte],
    now: Nanos,
): Result[Established, HelloFailure] =
  ## [SPEC TRANSPORT §3.1, §8.1, §8.1.1] The callee's Hello checks, in order:
  ## module, token (validated without consuming), schema, then the atomic
  ## redemption. A failure sends ProtocolError with `code` and closes; no
  ## failure consumes a live ticket. A first message that is not a Hello
  ## fails the same way [IMPL-DECISION G30].
  let first = ?readFirst(frame)
  if first.message.kind != mkHello:
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
  let redeemed = tickets.redeem(h.token, now).valueOr:
    return err(failure(ecNotAuthorised, hrRedeem, NotAuthorisedMessage))
  # [SPEC TRANSPORT §8.1] The response never echoes the ticket; this profile
  # defines no response material, so the token is empty.
  let response = encodeMessage(
    Message(
      kind: mkHello,
      hello: Hello(module: redeemed.provider, token: @[], schema: redeemed.contract),
    )
  ).valueOr:
    return err(failure(ecInvalidParams, hrEnvelope, $error))
  ok(Established(response: response, binding: redeemed))

# Caller ----------------------------------------------------------------------------

proc helloRequest*(
    module: string, ticket: openArray[byte], contract: Digest
): Result[seq[byte], EnvelopeError] =
  ## [SPEC TRANSPORT §3.1, §8.1] The caller's Hello: the selected provider, the
  ## one-time ticket, and the selected contract.
  encodeMessage(
    Message(
      kind: mkHello, hello: Hello(module: module, token: @ticket, schema: contract)
    )
  )

proc acceptHelloResponse*(
    sent: Hello, frame: openArray[byte]
): Result[void, HelloFailure] =
  ## [SPEC TRANSPORT §3.1, §10.1] The callee's answer: the same module, an empty
  ## token [IMPL-DECISION G33], then the same contract. A ProtocolError is the
  ## callee refusing the Hello; its code is the outcome [IMPL-DECISION G34].
  let first = ?readFirst(frame)
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
    var f = failure(m.protocolError.code, hrPeer, "the callee refused the Hello")
    f.peer = true
    err(f)
  else:
    err(failure(ecInvalidParams, hrEnvelope, "the first answer is not a Hello"))
