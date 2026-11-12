## RUNTIME §4.1-§4.3, §7.5, §9.3: direct routes as the Runtime thread keeps
## them.
##
## A route binds one consumer module instance to one selected provider and one
## exact selected contract, with a method and event access scope (§9.3
## `route_record`). This module holds the data and the pure checks; the engine
## orders every change to it on the Runtime thread.
##
## The selected contract is resolved from the provider's validated call
## surface (INTERFACE §2.6): the primary concrete contract exposes the methods
## and events of the primary document and of every implemented interface, an
## implemented interface exposes only its own (the same rule as the Transport
## boundary, `transport/boundary.nim`). An access list item is the schema
## subtree root of a method or event declaration under that contract
## (COMMITMENT §9.2 `declarationRoot`); a method list may also hold the root of
## the pinned common schema's well-known `logos.schema` method (§9.3
## l.2988-2994).

{.push raises: [].}

import std/[deques, sets, tables]
import results
import ../cbor
import ../commitment
import ../hash/hashinput
import ../iface/[accept, names, outcome]
import ./rc_types

export rc_types

const MaxRetainedKeys* = 4096
  ## [IMPL] successful route-operation results kept per consumer for
  ## `request_key` replay (§9.3 l.3176-3183); the oldest is dropped first, and
  ## a dropped key is evaluated afresh

type
  SelectedContract* = object
    ## The exact contract one route selects: what it exposes, by name, with
    ## each declaration's subtree root.
    root*: Digest
    module*: string ## the provider's runtime module name
    methods*: Table[string, Digest] ## bare method name -> declaration root
    events*: Table[string, Digest] ## event identifier -> declaration root
    wellKnown*: Table[string, Digest]
      ## the common schema's well-known methods (`schema`) -> declaration root

  RouteState* = enum
    ## [SPEC RUNTIME §9.3] `route_state`, the values a direct route takes:
    ## established routes are `ready` at once (§9.3 l.3144-3146).
    rtReady = "ready"
    rtClosed = "closed"
    rtFailed = "failed"
    rtRevoked = "revoked"

  RouteFailureCode* = enum
    ## [SPEC RUNTIME §9.3 l.2499-2519] `route_failure.code`.
    rfAuthorityDenied = "authority-denied"
    rfAuthorityEvaluationFailed = "authority-evaluation-failed"
    rfAuthorityExpired = "authority-expired"
    rfAuthorityRevoked = "authority-revoked"
    rfListenerDisabled = "listener-disabled"
    rfExportDisabled = "export-disabled"
    rfConsumerUnavailable = "consumer-unavailable"
    rfProviderUnavailable = "provider-unavailable"
    rfContractMismatch = "contract-mismatch"
    rfFacadeFailed = "facade-failed"
    rfRemoteUnreachable = "remote-unreachable"
    rfRemoteNotReady = "remote-not-ready"
    rfRemoteStopped = "remote-stopped"
    rfRemoteFailed = "remote-failed"
    rfTransportError = "transport-error"
    rfRouteTimeout = "route-timeout"
    rfOther = "other"

  Pin* = object ## One unreleased handle of a route.
    handle*: pointer
    attempt*: string ## the execution attempt that materialized it

  Route* = ref object ## One route, owned by the Runtime thread.
    id*: string
    consumer*: string ## the consumer module instance
    provider*: string ## the selected provider record
    providerInstance*: string ## the local module instance behind it
    selected*: SelectedContract
    access*: LogosNSRuntimeControlRouteAccess ## as requested and validated
    state*: RouteState
    failure*: Opt[RouteFailureCode]
    endCode*: ErrorCode
      ## [SPEC RUNTIME §7.5] what a new operation through one of its handles
      ## gets once it is terminal: NOT_AUTHORISED for withdrawn or expired
      ## authority, otherwise NOT_READY; the first cause is kept
    decisionId*: string ## the provider-access decision (§9.3 `decision_id`)
    expiresAt*: Opt[uint64]
      ## [SPEC RUNTIME l.3157-3166; I85] a Capability Authority route allow's
      ## `valid_until`, wall-clock milliseconds; none under internal policy
    monoDeadline*: Opt[int64]
      ## [RUN-0939] the engine clock's monotonic nanoseconds at which it
      ## expires, fixed when `expiresAt` was set
    grants*: seq[string] ## the grants its decision used
    authority*: bool ## its decision came from the Capability Authority
    handles*: seq[pointer] ## handles observing its end (`observe_end`)
    calls*: seq[pointer] ## the tickets of calls admitted through it
    subs*: seq[pointer]
      ## the subscriptions of its unreleased handles, active or not, in
      ## creation order (INTERFACE §2.5); `events.nim` keeps their state
    nextSub*: uint64 ## the last subscription id issued on it
    pins*: seq[Pin]
      ## its unreleased handles; one whose attempt's context is destroyed no
      ## longer counts (INTERFACE l.2004-2006)
    pending*: int ## asynchronous calls submitted through it and still recorded
    droppable*: bool ## ended and reachable through nothing: its record may be dropped
    dropped*: bool ## [IMPL] dropped: its id is unknown from then on

  KeyEntry = object
    operation: string
    request: seq[byte]
    response: seq[byte]

  RequestKeys* = object
    ## [SPEC RUNTIME §9.3 l.3176-3183] `request_key` values, scoped to the
    ## authenticated consumer (this Runtime instance is the only one here).
    entries: Table[(string, string), KeyEntry]
    order: Table[string, Deque[string]]

# The selected contract -------------------------------------------------------------

func wellKnownRoots*(ctx: SchemaContext): Table[string, Digest] =
  ## [SPEC INTERFACE §1.4; RUNTIME §9.3 l.2990-2992] The pinned common schema's
  ## well-known methods by bare name, with their declaration roots.
  for (name, kind, _) in ctx.common:
    if kind == dkMethod:
      let d = ctx.commonModel.find(name)
      if d.isSome:
        result[bareMethodName(name, ctx.commonModel.namespace)] =
          declarationRoot(ctx.commonModel, d.get)

func addContract(s: var SelectedContract, c: Contract) =
  for m in c.model.methods:
    s.methods[bareMethodName(m.name, c.model.namespace)] = declarationRoot(c.model, m)
  for e in c.model.events:
    s.events[e.name] = declarationRoot(c.model, e)

func selectContract*(
    b: ModuleBinding, root: Digest, ctx: SchemaContext
): Opt[SelectedContract] =
  ## [SPEC RUNTIME §4.2, §9.3 l.2924-2928] The contract `root` selects on a
  ## provider with the validated binding `b`: its primary concrete contract or
  ## one implemented interface, else none.
  var s = SelectedContract(root: root, module: b.module, wellKnown: wellKnownRoots(ctx))
  if b.primary.isSome and b.primary.get.root == root:
    s.addContract(b.primary.get)
    for i in b.interfaces:
      s.addContract(i)
    return Opt.some(s)
  for i in b.interfaces:
    if i.root == root:
      s.addContract(i)
      return Opt.some(s)
  Opt.none(SelectedContract)

func offers*(b: ModuleBinding, root: Digest): bool =
  ## Whether `root` names the provider's primary contract or an implemented
  ## interface.
  if b.primary.isSome and b.primary.get.root == root:
    return true
  for i in b.interfaces:
    if i.root == root:
      return true
  false

func methodRoot*(s: SelectedContract, bare: string): Opt[Digest] =
  ## The declaration root of a method the contract exposes, or of a
  ## well-known method.
  if bare in s.methods:
    return Opt.some(s.methods.getOrDefault(bare))
  if bare in s.wellKnown:
    return Opt.some(s.wellKnown.getOrDefault(bare))
  Opt.none(Digest)

func isWellKnown*(s: SelectedContract, bare: string): bool =
  bare notin s.methods and bare in s.wellKnown

func eventRoot*(s: SelectedContract, eventId: string): Opt[Digest] =
  ## The declaration root of an event the contract exposes.
  if eventId in s.events:
    return Opt.some(s.events.getOrDefault(eventId))
  Opt.none(Digest)

# Access scope ----------------------------------------------------------------------

func toDigest*(b: openArray[byte]): Opt[Digest] =
  if b.len != DigestLen:
    return Opt.none(Digest)
  var d: Digest
  for i, x in b:
    d[i] = x
  Opt.some(d)

func ascending(list: seq[seq[byte]]): bool =
  ## Strictly ascending by each item's Logos deterministic-CBOR bytes.
  for i in 1 ..< list.len:
    if cmpBytes(encodeCbor(cbor(list[i - 1])), encodeCbor(cbor(list[i]))) >= 0:
      return false
  true

func checkAccessOrder*(a: LogosNSRuntimeControlRouteAccess): Result[void, string] =
  ## [SPEC RUNTIME §9.3 l.2999-3001] Every present list strictly ascending,
  ## without duplicates; nothing is sorted or deduplicated for the caller.
  for (name, list) in [
    ("methods", a.methods),
    ("publish_events", a.publish_events),
    ("subscribe_events", a.subscribe_events),
  ]:
    if list.isSome and not ascending(list.get):
      return err("route_access." & name & " is not strictly ascending")
  ok()

func checkAccessRoots*(
    a: LogosNSRuntimeControlRouteAccess, s: SelectedContract
): Result[void, string] =
  ## [SPEC RUNTIME §4.3, §9.3 l.2993-2994] Every listed root is a declaration
  ## of the selected contract (a method list may also hold a well-known
  ## method's root).
  var methodRoots, eventRoots: HashSet[Digest]
  for r in s.methods.values:
    methodRoots.incl(r)
  for r in s.wellKnown.values:
    methodRoots.incl(r)
  for r in s.events.values:
    eventRoots.incl(r)
  if a.methods.isSome:
    for item in a.methods.get:
      let d = toDigest(item)
      if d.isNone or d.get notin methodRoots:
        return err("a method root is not a method of the selected contract")
  for list in [a.publish_events, a.subscribe_events]:
    if list.isSome:
      for item in list.get:
        let d = toDigest(item)
        if d.isNone or d.get notin eventRoots:
          return err("an event root is not an event of the selected contract")
  ok()

func allowsMethod*(r: Route, bare: string): bool =
  ## [SPEC RUNTIME §9.3 l.3003-3004] An absent list permits every method of the
  ## selected contract and the well-known `logos.schema`; an empty one none.
  let root = r.selected.methodRoot(bare)
  if root.isNone:
    return false
  if r.access.methods.isNone:
    return true
  for item in r.access.methods.get:
    if toDigest(item) == root:
      return true
  false

func listed(list: Opt[seq[seq[byte]]], root: Digest): bool =
  if list.isNone:
    return true
  for item in list.get:
    if toDigest(item) == Opt.some(root):
      return true
  false

func allowsPublish*(r: Route, eventId: string): bool =
  ## [SPEC RUNTIME §9.3 l.3014-3016] `publish_events` restricts what the
  ## provider may deliver on the route: absent permits every event of the
  ## selected contract, empty none.
  let root = r.selected.eventRoot(eventId)
  root.isSome and listed(r.access.publish_events, root.get)

func allowsSubscribe*(r: Route, eventId: string): bool =
  ## [SPEC RUNTIME §9.3 l.3027-3030] `subscribe_events` restricts what the
  ## consumer may subscribe to and receive.
  let root = r.selected.eventRoot(eventId)
  root.isSome and listed(r.access.subscribe_events, root.get)

# Route state -----------------------------------------------------------------------

func isTerminal*(r: Route): bool =
  r.state != rtReady

func reachable*(r: Route): bool =
  ## [SPEC RUNTIME §7.5 l.1346] Whether something can still reach the record
  ## by its route: an unreleased handle, a handle observing its end, an
  ## admitted call, or a submitted call. A handle's subscriptions go with it.
  r.pins.len > 0 or r.handles.len > 0 or r.calls.len > 0 or r.pending > 0

func terminate*(r: Route, state: RouteState, failure: Opt[RouteFailureCode]) =
  ## [SPEC RUNTIME §7.5, §9.3 l.3226-3229] The route takes no new calls. Only
  ## the first terminal transition counts.
  if r.isTerminal:
    return
  r.state = state
  r.failure = failure
  r.endCode =
    if failure.isSome and
        failure.get in {
          rfAuthorityDenied, rfAuthorityEvaluationFailed, rfAuthorityExpired,
          rfAuthorityRevoked,
        }: ecNotAuthorised else: ecNotReady

func routeState*(s: RouteState): LogosNSRuntimeControlRouteState =
  LogosNSRuntimeControlRouteState(
    kind:
      case s
      of rtReady: LogosNSRuntimeControlRouteStateKind.Ready
      of rtClosed: LogosNSRuntimeControlRouteStateKind.Closed
      of rtFailed: LogosNSRuntimeControlRouteStateKind.Failed
      of rtRevoked: LogosNSRuntimeControlRouteStateKind.Revoked
  )

func schemaCommitmentOf*(root: Digest): SchemaCommitment =
  SchemaCommitment(schema_root: @root)

func record*(r: Route, runtimeId: string): LogosNSRuntimeControlRouteRecord =
  ## [SPEC RUNTIME §9.3] The route as Runtime Control exposes it. A direct
  ## route never carries `invocation` (l.3469). Internal policy has no
  ## validity end, so no `expires_at` (l.2954-2955); a Capability Authority
  ## route carries its allow's `valid_until` (l.3157-3166; RUN-0938).
  result = LogosNSRuntimeControlRouteRecord(
    route: r.id,
    consumer: LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: runtimeId, module_instance_id: r.consumer
    ),
    target_provider: LogosNSRuntimeModuleProviderAddress(
      provider: r.provider, runtime_instance_id: Opt.some(runtimeId)
    ),
    module: r.selected.module,
    instance: Opt.some(r.providerInstance),
    expected_contract: Opt.some(schemaCommitmentOf(r.selected.root)),
    access: r.access,
    state: routeState(r.state),
  )
  if r.decisionId.len > 0:
    result.decision_id = Opt.some(r.decisionId)
  result.expires_at = r.expiresAt
  if r.state in {rtFailed, rtRevoked} and r.failure.isSome:
    # [SPEC RUNTIME §9.3 l.2520, l.2524] `failed` and `revoked` carry
    # `failure`; an explicit closure has none.
    result.failure = Opt.some(LogosNSRuntimeControlRouteFailure(code: $r.failure.get))

# request_key replay ----------------------------------------------------------------

func replay*(
    k: RequestKeys, consumer, key, operation: string, request: openArray[byte]
): Result[Opt[seq[byte]], string] =
  ## [SPEC RUNTIME §9.3 l.3176-3183, l.3591] The retained result for a reused
  ## key and the same request; an error for a reused key with other fields or
  ## another operation; none for a key with no retained result.
  let e = k.entries.getOrDefault((consumer, key))
  if e.operation.len == 0:
    return ok(Opt.none(seq[byte]))
  if e.operation != operation or e.request != @request:
    return err("the request_key was used for a different request")
  ok(Opt.some(e.response))

proc retain*(
    k: var RequestKeys, consumer, key, operation: string, request, response: seq[byte]
) =
  ## Keeps a successful result for replay; the consumer's oldest is dropped
  ## past `MaxRetainedKeys`.
  if (consumer, key) notin k.entries:
    var q = k.order.getOrDefault(consumer)
    if q.len >= MaxRetainedKeys:
      k.entries.del((consumer, q.popFirst()))
    q.addLast(key)
    k.order[consumer] = q
  k.entries[(consumer, key)] =
    KeyEntry(operation: operation, request: request, response: response)
