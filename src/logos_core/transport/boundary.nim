## TRANSPORT §4.1, §8.1, §8.3: the schema-aware sending and receiving boundaries
## of one provider session. The sender validates a payload and computes its
## commitment; the receiver resolves the target under the session's selected
## contract, checks the route's access scope, then compares the subtree root,
## validates, and recomputes and compares the value root, before a Request is
## dispatched, a `response-ok` accepted or an Event delivered.

{.push raises: [].}

import std/sets
import results
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/hash
import logos_sdk/iface/[outcome, payload, surface]
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
    scoped: bool ## whether a route access scope restricts the selected contract
    methodScope, eventScope: HashSet[string]

  RejectKind* = enum
    rjRespond ## answer with this failure (the call fails, the session stays)
    rjClose ## ProtocolError with `failure.code` and close the provider session
    rjOwner
      ## [SPEC RUNTIME l.1827-1828; re-pin P4b] a Request whose params fail
      ## their schema: dispatched all the same, for its owner to fail the call
      ## as in direct mode, after the call's authorization

  RejectCause* = enum
    ## Which receiving check failed (§4.1, §8.1), in the order they run.
    rcUnknownTarget ## the name is not in the selected contract
    rcScope ## outside the route's access scope (§8.1)
    rcSubtreeRoot ## `schema_subtree_root` differs from the declaration's
    rcSchema ## the payload fails its declaration
    rcValueRoot ## `value_root` differs from the recomputed one
    rcResource
      ## the commitment could not be recomputed within the commitment layer's
      ## limits: no mismatch is established, so it is never reported as one

  Reject* = object
    kind*: RejectKind
    cause*: RejectCause
    failure*: InvocationFailure
    msg*: string

func reject(
    kind: RejectKind, cause: RejectCause, code: ErrorCode, msg: string
): Reject =
  Reject(kind: kind, cause: cause, failure: InvocationFailure(code: code), msg: msg)

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

func withAccess*(
    b: Boundary, methods: openArray[string], events: openArray[string]
): Boundary =
  ## [SPEC TRANSPORT §5.1, §8.1, §8.1.2] The route's (or system-service
  ## binding's) method-call and event-subscription access, as bare method names
  ## (`schema` included when the route allows introspection) and exact event
  ## names. Without it, the whole selected contract is in scope. Names are still
  ## resolved under the selected contract first; the scope never widens it.
  var r = b
  r.scoped = true
  r.methodScope = toHashSet(methods)
  r.eventScope = toHashSet(events)
  r

func allowsMethod*(b: Boundary, methodName: string): bool =
  not b.scoped or methodName in b.methodScope

func allowsEvent*(b: Boundary, eventId: string): bool =
  not b.scoped or eventId in b.eventScope

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

func marked*(b: Boundary, methodName: string): tuple[request, response: bool] =
  ## [SPEC INTERFACE §1.2.1] Which payloads of a method of the selected contract
  ## `_sensitive` marks; none for a well-known method or an unknown name.
  if b.isWellKnown(methodName):
    return (false, false)
  let m = b.surface.findMethod(methodName).valueOr:
    return (false, false)
  (m.sensitiveRequest, m.sensitiveResponse)

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
  ## subtree root and the value root under the defining contract. In the marked
  ## scope the normalized and laid-out trees, which copy the payload's scalars,
  ## are wiped once the root is taken [DECISIONS G276].
  var r = ?t.set.normalize(0, t.declaration, v)
  var laid = layout(r)
  if inMarkedScope():
    wipe(r.node)
  if laid.isErr:
    return err(laid.error)
  let c = PayloadCommitment(subtreeRoot: r.subtreeRoot, valueRoot: laid.get.digest)
  if inMarkedScope():
    wipe(laid.value)
  ok(c)

# Sending ---------------------------------------------------------------------------
#
# A sending failure is a `Reject` too: `cause` says which check failed
# (`rcUnknownTarget`, `rcSchema` with INVALID_PARAMS, `rcResource` with
# MODULE_ERROR) and nothing is sent.

func send(t: Target, v: CborValue): Result[PayloadCommitment, Reject] =
  ## [SPEC TRANSPORT §4.1] The sending boundary computes the commitment from the
  ## validated schema-typed value. The caller sets the marked scope.
  t.validate(v).isOkOr:
    return err(
      reject(
        rjRespond, rcSchema, ecInvalidParams, "the value is not a " & t.declaration
      )
    )
  let c = t.commit(v).valueOr:
    return err(
      reject(
        rjRespond, rcResource, ecModule, "the commitment cannot be computed: " & error
      )
    )
  ok(c)

func commitRequest*(
    b: Boundary, methodName: string, params: CborValue
): Result[PayloadCommitment, Reject] =
  let t = b.requestTarget(methodName, false).valueOr:
    return err(
      reject(
        rjRespond,
        rcUnknownTarget,
        ecMethodNotFound,
        methodName & " is not a method of the selected contract",
      )
    )
  markedScope(b.marked(methodName).request):
    result = t.send(params)

func commitResponse*(
    b: Boundary, methodName: string, value: CborValue
): Result[PayloadCommitment, Reject] =
  let t = b.requestTarget(methodName, true).valueOr:
    return err(
      reject(
        rjRespond,
        rcUnknownTarget,
        ecModule,
        methodName & " is not a method of the selected contract",
      )
    )
  markedScope(b.marked(methodName).response):
    result = t.send(value)

func commitEvent*(
    b: Boundary, eventId: string, data: CborValue
): Result[PayloadCommitment, Reject] =
  let t = b.eventTarget(eventId).valueOr:
    return err(
      reject(
        rjRespond,
        rcUnknownTarget,
        ecNotAuthorised,
        eventId & " is not an event of the selected contract",
      )
    )
  t.send(data)

# Receiving -------------------------------------------------------------------------

func recheckIn(
    t: Target, v: CborValue, c: PayloadCommitment, onSchema: RejectKind, marked: bool
): Result[void, Reject] =
  ## [SPEC TRANSPORT §4.1] The receiving order: (1) the subtree root, whose
  ## mismatch closes the session even when the payload also fails its schema;
  ## (2) the schema: a Request fails its call as in direct mode (INTERFACE
  ## §4.5) and the session stays, a response-ok or Event closes the session;
  ## (3) the value root of the validated value, whose mismatch closes. No root is
  ## computed for a schema-invalid payload. A commitment the commitment layer
  ## cannot compute is a resource failure, not a mismatch [IMPL]: the call fails
  ## with MODULE_ERROR, or a response-ok or Event closes the session with it.
  ## For a marked payload (`marked`, in the marked scope) the recomputed value
  ## root is zeroed after the comparison, and the validator's INVALID_PARAMS
  ## path stops before its first payload-derived segment [DECISIONS G276, G278].
  ## With `onSchema` `rjOwner` a schema failure carries no failure: the owner
  ## computes its own; a resource failure is still answered here.
  if c.subtreeRoot != t.subtreeRoot:
    return err(
      reject(rjClose, rcSubtreeRoot, ecInvalidParams, "schema_subtree_root differs")
    )
  let path = t.validate(v)
  if path.isErr:
    var r = reject(
      onSchema, rcSchema, ecInvalidParams, "the payload is not a " & t.declaration
    )
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
  var mine = t.commit(v).valueOr:
    return err(
      reject(
        (if onSchema == rjOwner: rjRespond else: onSchema),
        rcResource,
        ecModule,
        "the commitment cannot be computed: " & error,
      )
    )
  let same = mine.valueRoot == c.valueRoot
  if marked:
    wipe(mine)
  if not same:
    return err(reject(rjClose, rcValueRoot, ecInvalidParams, "value_root differs"))
  ok()

func recheck(
    t: Target, v: CborValue, c: PayloadCommitment, onSchema: RejectKind, marked: bool
): Result[void, Reject] =
  markedScope(marked):
    result = t.recheckIn(v, c, onSchema, marked)

func acceptRequest*(b: Boundary, r: Request): Result[void, Reject] =
  ## [SPEC TRANSPORT §4.1, §8.1, §8.3] Before dispatch: the bare method name
  ## resolved under the selected contract only (unknown: METHOD_NOT_FOUND), then
  ## the route's method scope (outside: NOT_AUTHORISED), then the commitment and
  ## schema checks of `recheck`. No provider code runs on any failure.
  ## [SPEC RUNTIME l.1824-1828; TRANSPORT §4.1 (2); re-pin P4b] A schema failure
  ## is `rjOwner`: the call fails "as in direct mode", where the Runtime's
  ## authorization of the call (step 2) comes before the payload's check (step
  ## 3). Its owner admits it, then checks the params under the same selected
  ## contract (`callProvider`, the Module Host's `runAdmitted`); the params go
  ## nowhere they would not go for a valid Request.
  let t = b.requestTarget(r.methodName, false).valueOr:
    return err(
      reject(
        rjRespond,
        rcUnknownTarget,
        ecMethodNotFound,
        r.methodName & " is not in the selected contract",
      )
    )
  if not b.allowsMethod(r.methodName):
    return err(
      reject(
        rjRespond,
        rcScope,
        ecNotAuthorised,
        r.methodName & " is outside the route scope",
      )
    )
  t.recheck(r.params, r.commitment, rjOwner, b.marked(r.methodName).request)

func acceptResponse*(
    b: Boundary, methodName: string, r: Response
): Result[void, Reject] =
  ## [SPEC TRANSPORT §4.1] Before a `response-ok` is accepted. Every failure
  ## closes the session, even when the invalid payload prevents recomputing its
  ## commitment; the waiting call gets TRANSPORT_ERROR (§3.2).
  if not r.ok:
    return ok()
  let t = b.requestTarget(methodName, true).valueOr:
    return err(
      reject(
        rjClose, rcUnknownTarget, ecInvalidParams, methodName & " is not a known method"
      )
    )
  t.recheck(r.resultMap, r.commitment, rjClose, b.marked(methodName).response)

func acceptEvent*(b: Boundary, e: Event): Result[void, Reject] =
  ## [SPEC TRANSPORT §4.1] Before an Event is delivered: a schema-invalid one
  ## closes the session and never reaches a subscription handler.
  let t = b.eventTarget(e.event).valueOr:
    return err(
      reject(
        rjClose,
        rcUnknownTarget,
        ecInvalidParams,
        e.event & " is not in the selected contract",
      )
    )
  t.recheck(e.data, e.commitment, rjClose, false)
