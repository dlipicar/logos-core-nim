## TRANSPORT §4.1, §8.3: the schema-aware sending and receiving boundaries of one
## provider session. The sender validates a payload and computes its commitment;
## the receiver resolves the target under the session's selected contract,
## validates, recomputes and compares, before a Request is dispatched, a
## `response-ok` accepted or an Event delivered.

{.push raises: [].}

import results
import ../cbor
import ../commitment
import ../hash
import ../iface/[outcome, payload, surface]
import ./envelope

export results

type
  Target = object
    set: SchemaSet ## the defining document is document 0
    declaration: string

  Boundary* = object
    ## The selected contract of one provider session [SPEC TRANSPORT §3.1, §8.1].
    contracts*: ContractSet
    selected*: Digest ## the root the Hello bound
    surface*: CallSurface ## what the selected contract exposes, and nothing else
    sets: seq[SchemaSet] ## one per `contracts.documents` entry
    common: SchemaSet
    wellKnown: seq[string]

  RejectKind* = enum
    rjRespond ## answer with this failure (the call fails, the session stays)
    rjClose ## ProtocolError INVALID_PARAMS and close the provider session (§4.1)

  Reject* = object
    kind*: RejectKind
    failure*: InvocationFailure
    msg*: string

func reject(kind: RejectKind, code: ErrorCode, msg: string): Reject =
  Reject(kind: kind, failure: InvocationFailure(code: code), msg: msg)

func boundary*(s: ContractSet, selected: Digest): Result[Boundary, string] =
  ## [SPEC TRANSPORT §3.1, §8.1] The session's selected contract: the primary
  ## concrete contract (its whole call surface), or one implemented interface
  ## (only that interface's methods and events; never the provider's others).
  var b = Boundary(
    contracts: s,
    selected: selected,
    common: schemaSet(s.context.commonModel),
    wellKnown: wellKnownMethods(s.context),
  )
  for c in s.documents:
    b.sets.add(schemaSetFor(c.model, s.context))
  let full = s.callSurface
  if selected == s.primary.root:
    b.surface = full
  else:
    var found = false
    for c in s.interfaces:
      if c.root == selected:
        found = true
    if not found:
      return
        err("the selected contract is neither the primary nor an implemented interface")
    for m in full.methods:
      if m.contract == selected:
        b.surface.methods.add(m)
    for e in full.events:
      if e.contract == selected:
        b.surface.events.add(e)
  ok(b)

func isWellKnown(b: Boundary, methodName: string): bool =
  methodName in b.wellKnown

func requestTarget(b: Boundary, methodName: string, response: bool): Opt[Target] =
  ## The defining document and declaration of a method's request or response.
  ## `logos.schema` is defined by the pinned common schema (§4.1).
  if b.isWellKnown(methodName):
    let name = "logos." & methodName & (if response: "_response" else: "_request")
    return Opt.some(Target(set: b.common, declaration: name))
  let m = b.surface.findMethod(methodName).valueOr:
    return Opt.none(Target)
  Opt.some(
    Target(set: b.sets[m.doc], declaration: (if response: m.response else: m.request))
  )

func eventTarget(b: Boundary, eventId: string): Opt[Target] =
  let e = b.surface.findEvent(eventId).valueOr:
    return Opt.none(Target)
  Opt.some(Target(set: b.sets[e.doc], declaration: e.id))

func knowsMethod*(b: Boundary, methodName: string): bool =
  b.isWellKnown(methodName) or b.surface.findMethod(methodName).isSome

func knowsEvent*(b: Boundary, eventId: string): bool =
  b.surface.findEvent(eventId).isSome

func isIntrospection*(b: Boundary, methodName: string): bool =
  ## [SPEC TRANSPORT §8.1] `logos.schema`, answered by the provider-side boundary.
  b.isWellKnown(methodName)

func subtreeRoot(t: Target): Digest =
  let m = t.set.docs[0]
  declarationRoot(m, m.find(t.declaration).get)

func validate(t: Target, v: CborValue): Result[void, seq[CborValue]] =
  t.set.validatePath(0, t.set.docs[0].find(t.declaration).get.body, v)

func commit(t: Target, v: CborValue): Result[PayloadCommitment, string] =
  ## [SPEC TRANSPORT §4.1] The roots of a validated value: the declaration's
  ## subtree root and the value root under the defining contract.
  let r = ?t.set.normalize(0, t.declaration, v)
  ok(PayloadCommitment(subtreeRoot: r.subtreeRoot, valueRoot: ?valueRoot(r)))

# Sending ---------------------------------------------------------------------------

func send(t: Target, v: CborValue): Result[PayloadCommitment, string] =
  ## [SPEC TRANSPORT §4.1] The sending boundary computes the commitment from the
  ## validated schema-typed value.
  t.validate(v).isOkOr:
    return err("the value is not a " & t.declaration)
  t.commit(v)

func commitRequest*(
    b: Boundary, methodName: string, params: CborValue
): Result[PayloadCommitment, string] =
  let t = b.requestTarget(methodName, false).valueOr:
    return err(methodName & " is not a method of the selected contract")
  t.send(params)

func commitResponse*(
    b: Boundary, methodName: string, value: CborValue
): Result[PayloadCommitment, string] =
  let t = b.requestTarget(methodName, true).valueOr:
    return err(methodName & " is not a method of the selected contract")
  t.send(value)

func commitEvent*(
    b: Boundary, eventId: string, data: CborValue
): Result[PayloadCommitment, string] =
  let t = b.eventTarget(eventId).valueOr:
    return err(eventId & " is not an event of the selected contract")
  t.send(data)

# Receiving -------------------------------------------------------------------------

func recheck(
    t: Target, v: CborValue, c: PayloadCommitment, onSchema: RejectKind
): Result[void, Reject] =
  ## The receiving order: the subtree root first, then the schema, then the value
  ## root [IMPL-DECISION G37]. A root that differs closes the session (§4.1); a
  ## value outside the schema closes it for a response or event (G36) and fails
  ## the call for a request, as it would in direct mode (INTERFACE §4.5).
  if c.subtreeRoot != t.subtreeRoot:
    return err(reject(rjClose, ecInvalidParams, "schema_subtree_root differs"))
  let path = t.validate(v)
  if path.isErr:
    var r = reject(onSchema, ecInvalidParams, "the payload is not a " & t.declaration)
    if onSchema == rjRespond:
      r.failure = toFailure(
        PayloadError(
          code: ecInvalidParams,
          reason: Opt.some(iprSchemaMismatch),
          path: path.error,
          msg: r.msg,
        )
      )
    return err(r)
  let mine = t.commit(v).valueOr:
    return err(reject(rjClose, ecInvalidParams, error))
  if mine.valueRoot != c.valueRoot:
    return err(reject(rjClose, ecInvalidParams, "value_root differs"))
  ok()

func acceptRequest*(b: Boundary, r: Request): Result[void, Reject] =
  ## [SPEC TRANSPORT §4.1, §8.1, §8.3] Before dispatch: the bare method name
  ## resolved under the selected contract only (unknown: METHOD_NOT_FOUND, no
  ## provider code runs), then the commitment and the schema.
  let t = b.requestTarget(r.methodName, false).valueOr:
    return err(
      reject(
        rjRespond, ecMethodNotFound, r.methodName & " is not in the selected contract"
      )
    )
  t.recheck(r.params, r.commitment, rjRespond)

func acceptResponse*(
    b: Boundary, methodName: string, r: Response
): Result[void, Reject] =
  ## [SPEC TRANSPORT §4.1] Before a `response-ok` is accepted. Every failure
  ## closes the session; the waiting call gets TRANSPORT_ERROR [IMPL-DECISION G36].
  if not r.ok:
    return ok()
  let t = b.requestTarget(methodName, true).valueOr:
    return err(reject(rjClose, ecInvalidParams, methodName & " is not a known method"))
  t.recheck(r.resultMap, r.commitment, rjClose)

func acceptEvent*(b: Boundary, e: Event): Result[void, Reject] =
  ## [SPEC TRANSPORT §4.1] Before an Event is delivered [IMPL-DECISION G36].
  let t = b.eventTarget(e.event).valueOr:
    return err(
      reject(rjClose, ecInvalidParams, e.event & " is not in the selected contract")
    )
  t.recheck(e.data, e.commitment, rjClose)
