## Step 8b (DECISIONS I85): from an engine `AuthzRequest` to a Capability
## Authority `evaluate_request`, and the checks of a decision against the
## request it answers.
##
## Requests (CA §3, §5; RUNTIME §9):
## - The consumer is the module instance whose operation it is: the engine is
##   never one (CAP-0011, CAP-0013, CAP-0014, RUN-0324, RUN-0858; BCP-0073).
## - One request is one operation: exactly one non-permission scope, naming
##   only the action being evaluated (CAP-0096, CAP-0097; 8a's G207 shape). A
##   `stop_module` is two requests decided together: its Runtime Control scope
##   and its `module_execution` `stop` scope (CA l.335).
## - Every array the Runtime builds is a set in deterministic-CBOR order
##   (CAP-0022 to CAP-0024), and every provider address carries the Runtime id
##   (CAP-0038, CAP-0039). Contract commitments and declaration roots are the
##   resolved ones; the Runtime Control and Capability Authority roots are
##   recomputed from the mirrored contracts (CAP-0089, CAP-0090).
## - [IMPL] A Runtime Control scope carries every selector the operation
##   determines (`modules` and `instances` for an instance target, `providers`
##   for a provider target, `routes` for a route), so a grant on any one of
##   them covers it (CA l.119-131). 8a's policy matcher then needs
##   Runtime Control rules that target `modules` or nothing.
## - No `commitment` is sent: the Runtime adds no retention of its own.
## - The execution decision carries no permission scopes (TF-32, G217).
##
## Decisions (CA §5, l.554-573), checked off the Runtime thread. Every failure
## is an evaluation failure, never a deny (CAP-0118, CAP-0260, CAP-0261,
## RUN-0327): the consumer and the requested scopes match the request; every
## received set is ordered; the allow and deny arms carry only their fields;
## `valid_until` follows `issued_at`; every allowed scope is covered by a
## requested one and every requested scope covers an allowed one (8a's
## `covers`, alternatives never combined); nothing allowed lacks an
## enforcement point here (placements, a mode other than direct, permission or
## remote-enrollment scopes; CAP-0084, CAP-0068); and an allow that keeps a
## route usable has `valid_until` (CAP-0049, RUN-0566; S8b-2 interim, TF-33).

{.push raises: [].}

import std/[strutils, tables]
import results
import ../cbor
import ../iface/common_types
import ../authority/scopes
from ./rc_types import LogosNSRuntimeControlRouteAccess, decode
import ./authz

type
  EvaluateRequest* = LogosNSCapabilityAuthorityEvaluateRequest
  EvaluateResponse* = LogosNSCapabilityAuthorityEvaluateResponse
  GrantChanged* = LogosNSCapabilityAuthorityGrantChangedEvent

func codeText(s: string): string =
  ## A generated enum name (`Not_granted`) as its CDDL text (`not-granted`).
  s.toLowerAscii.replace('_', '-')

proc address*(runtimeId, instance: string): Address =
  Address(runtime_instance_id: runtimeId, module_instance_id: instance)

proc providerAddress(runtimeId, provider: string): ProviderAddress =
  ProviderAddress(provider: provider, runtime_instance_id: Opt.some(runtimeId))

proc routeAccess(bytes: openArray[byte]): Result[Opt[RouteAccess], string] =
  if bytes.len == 0:
    return ok(Opt.none(RouteAccess))
  let a = LogosNSRuntimeControlRouteAccess.decode(bytes).valueOr:
    return err("the route access does not decode: " & error)
  ok(
    Opt.some(
      RouteAccess(
        methods: a.methods,
        publish_events: a.publish_events,
        subscribe_events: a.subscribe_events,
      )
    )
  )

proc controlScope(q: AuthzRequest, runtimeId: string): Result[Scope, string] =
  if q.operation notin rcContractInfo().methods:
    return err("no Runtime Control method " & q.operation)
  var s = RuntimeControlScope(
    runtime: runtimeId,
    contract: rcContract(),
    methods: Opt.some(@[rcMethodRoot(q.operation)]),
  )
  case q.action
  of aaRuntimeControl:
    if q.route.len > 0:
      s.routes = Opt.some(@[q.route])
  else:
    if q.providerSelector:
      s.providers = Opt.some(@[providerAddress(runtimeId, q.provider)])
    else:
      if q.module.len > 0:
        s.modules = Opt.some(@[q.module])
      if q.instance.len > 0:
        s.instances = Opt.some(@[q.instance])
  ok(toScope(s))

proc executionScope(
    q: AuthzRequest, runtimeId: string, action: MeActionKind
): Result[Scope, string] =
  if q.module.len == 0 or q.instance.len == 0:
    return err("an execution request names no module instance")
  ok(
    toScope(
      ModuleExecutionScope(
        runtime: runtimeId,
        module: q.module,
        instance: Opt.some(q.instance),
        actions: @[MeAction(kind: action)],
        modes: Opt.some(@[ExecMode(kind: ExecModeKind.Direct)]),
      )
    )
  )

proc accessScope(q: AuthzRequest, runtimeId: string): Result[Scope, string] =
  if q.contract.len != 32:
    return err("a provider-access request names no contract")
  var s = ProviderAccessScope(contract: SchemaCommitment(schema_root: q.contract))
  template one(action: PaActionKind) =
    s.actions = @[PaAction(kind: action)]

  template routed() =
    if q.provider.len == 0 or q.route.len == 0:
      return err("a routed request names no provider or route")
    s.providers = Opt.some(@[providerAddress(runtimeId, q.provider)])
    s.routes = Opt.some(@[q.route])

  template declared(): seq[seq[byte]] =
    if q.declaration.len != 32:
      return err("a routed request names no declaration")
    @[q.declaration]

  case q.action
  of aaRoute:
    case q.operation
    of "establish_route":
      one(PaActionKind.Establish_route)
    of "renew_route":
      one(PaActionKind.Renew_route)
    else:
      return err("no route action for " & q.operation)
    routed()
    s.access = ?routeAccess(q.access)
  of aaCall:
    one(PaActionKind.Call)
    routed()
    s.access = Opt.some(RouteAccess(methods: Opt.some(declared())))
  of aaPublishEvent:
    one(PaActionKind.Publish_event)
    routed()
    s.access = Opt.some(RouteAccess(publish_events: Opt.some(declared())))
  of aaSubscribeEvent:
    one(PaActionKind.Subscribe_event)
    routed()
    s.access = Opt.some(RouteAccess(subscribe_events: Opt.some(declared())))
  of aaDiscover:
    one(PaActionKind.Discover)
  else:
    return err("no provider-access scope for " & $q.action)
  ok(toScope(s))

proc evaluateRequest*(
    q: AuthzRequest, runtimeId: string
): Result[EvaluateRequest, string] =
  ## [SPEC CA §5; plan §2.5] The one `evaluate_request` for `q`.
  if q.consumer.len == 0:
    return err("the host is never a consumer")
  var scope =
    case q.action
    of aaRuntimeControl, aaLifecycle, aaObserve:
      ?controlScope(q, runtimeId)
    of aaExecute:
      ?executionScope(q, runtimeId, MeActionKind.Start)
    of aaStop:
      ?executionScope(q, runtimeId, MeActionKind.Stop)
    of aaRoute, aaCall, aaPublishEvent, aaSubscribeEvent, aaDiscover:
      ?accessScope(q, runtimeId)
  var scopes = @[scope]
  canonicalOrder(scopes)
  ok(EvaluateRequest(consumer: address(runtimeId, q.consumer), scopes: scopes))

proc encodeRequest*(q: AuthzRequest, runtimeId: string): Result[seq[byte], string] =
  encode(?evaluateRequest(q, runtimeId))

# Decisions ----------------------------------------------------------------------------

func failed(reason: string, errorCode = ""): EvalResult =
  EvalResult(verdict: evFailed, reason: reason, errorCode: errorCode)

proc sameScopes(a, b: openArray[Scope]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if enc(a[i]) != enc(b[i]):
      return false
  true

proc keepsRoute(scopes: openArray[Scope]): bool =
  for s in scopes:
    if s.kind == skProvider and (
      s.pa.hasAction(PaActionKind.Establish_route) or
      s.pa.hasAction(PaActionKind.Renew_route)
    ):
      return true
  false

proc enforceable(s: Scope): bool =
  ## [SPEC CA l.413; CAP-0084, CAP-0068] What this Runtime can enforce.
  case s.kind
  of skPermission, skEnrollment:
    false
  of skExecution:
    if s.me.placements.isSome:
      return false
    if s.me.modes.isSome:
      for m in s.me.modes.get:
        if m.kind != ExecModeKind.Direct:
          return false
    true
  else:
    true

proc checkDecision*(
    request: EvaluateRequest, d: Decision, localRuntime: string
): Result[void, string] =
  ## [SPEC CA l.554-573; plan §2.6] The checks of one decision against the
  ## request it answers.
  if d.consumer.runtime_instance_id != request.consumer.runtime_instance_id or
      d.consumer.module_instance_id != request.consumer.module_instance_id:
    return err("the decision names another consumer") # CAP-0112, RUN-0325
  if not sameScopes(d.requested_scopes, request.scopes):
    return err("the decision answers other scopes") # CAP-0112
  checkScopeSet(d.requested_scopes).isOkOr:
    return err("the requested scopes are not a set") # CAP-0025
  if d.allowed_scopes.isSome:
    if not isSet(d.allowed_scopes.get):
      return err("the allowed scopes are not a set")
    for s in d.allowed_scopes.get:
      checkScope(s).isOkOr:
        return err("an allowed scope has an array that is not a set")
  if d.grant_ids.isSome and not isSet(d.grant_ids.get):
    return err("the grant ids are not a set")
  case d.result.kind
  of LogosNSCapabilityAuthorityDecisionResultKind.Allow:
    # [SPEC CA l.556-560; CAP-0108, CAP-0110]
    if d.allowed_scopes.isNone or d.denial.isSome:
      return err("an allow without allowed scopes or with a denial")
  of LogosNSCapabilityAuthorityDecisionResultKind.Deny:
    # [SPEC CA l.561-563; CAP-0109]
    if d.denial.isNone or d.allowed_scopes.isSome or d.valid_until.isSome or
        d.grant_ids.isSome or d.commitment.isSome:
      return err("a deny without a denial or with allow fields")
  if d.valid_until.isSome and d.valid_until.get <= d.issued_at:
    return err("valid_until does not follow issued_at") # CAP-0111
  if d.allowed_scopes.isSome:
    let allowed = d.allowed_scopes.get
    for a in allowed:
      # [SPEC CA l.565-567; CAP-0113, CAP-0116, CAP-0117]
      if not coversAlternatives(request.scopes, a, localRuntime):
        return err("an allowed scope is not covered by a requested scope")
      if not enforceable(a):
        return err("an allowed scope has no enforcement point here") # CAP-0118
    for q in request.scopes:
      # [CAP-0114]
      var any = false
      for a in allowed:
        if covers(q, a, localRuntime):
          any = true
      if not any:
        return err("a requested scope covers no allowed scope")
    if keepsRoute(request.scopes) and d.valid_until.isNone:
      # [SPEC CA l.291; RUNTIME l.3157-3166; S8b-2 interim (TF-33)]
      return err("a route allow without valid_until")
  ok()

proc readDecision*(
    request: EvaluateRequest, response: openArray[byte], localRuntime: string
): EvalResult =
  ## [SPEC RUNTIME l.1737-1748; CA §5, §7] The verdict one `evaluate`
  ## response gives: an `error` arm or anything malformed is an evaluation
  ## failure (RUN-0329, CAP-0098), never a deny.
  let r = EvaluateResponse.decode(response).valueOr:
    return failed("the evaluate response does not decode: " & error)
  case r.kind
  of LogosNSCapabilityAuthorityEvaluateResponseKind.Map_error:
    let e = r.arm_Map_error.error
    return failed("the authority answered an error", codeText($e.code.kind))
  of LogosNSCapabilityAuthorityEvaluateResponseKind.Map_decision:
    discard
  let d = r.arm_Map_decision.decision
  checkDecision(request, d, localRuntime).isOkOr:
    return failed("a malformed decision: " & error)
  result = EvalResult(
    verdict:
      if d.result.kind == LogosNSCapabilityAuthorityDecisionResultKind.Allow:
        evAllow
      else:
        evDeny,
    decisionId: d.decision_id,
    policyRevision: d.policy_revision,
    issuedAt: d.issued_at,
    validUntil: d.valid_until,
    grants: d.grant_ids.get(@[]),
  )
  if d.commitment.isSome:
    result.retainRequest = d.commitment.get.request.isSome
    result.retainResponse = d.commitment.get.response.isSome
  if d.denial.isSome:
    result.denialCode = codeText($d.denial.get.code.kind)
  if d.allowed_scopes.isSome:
    for a in d.allowed_scopes.get:
      result.allowed.add(enc(a))

# Enforcement (Runtime thread) -----------------------------------------------------------

proc allowedScopes*(x: AuthzAnswer): seq[Scope] =
  for b in x.allowed:
    let s = Scope.decode(b)
    if s.isOk:
      result.add(s.get)

proc fits*(x: AuthzAnswer, request: EvaluateRequest, localRuntime: string): bool =
  ## [SPEC CA l.565-567; CAP-0115] The operation fits one allowed scope whole:
  ## alternatives are never combined.
  let allowed = x.allowedScopes
  for q in request.scopes:
    if q.kind == skPermission:
      continue
    var any = false
    for a in allowed:
      if covers(a, q, localRuntime):
        any = true
    if not any:
      return false
  true

proc allowedAccess*(
    x: AuthzAnswer, request: EvaluateRequest, localRuntime: string
): Opt[Opt[RouteAccess]] =
  ## [SPEC RUNTIME l.3164-3166; CA l.288; RUN-0567, CAP-0051] For an
  ## establish-route allow: the access of the allowed scope that fits the
  ## operation in everything but its access, which becomes the route's; none
  ## when no allowed scope fits.
  if request.scopes.len != 1 or request.scopes[0].kind != skProvider:
    return Opt.none(Opt[RouteAccess])
  let q = request.scopes[0]
  for a in x.allowedScopes:
    if a.kind != skProvider:
      continue
    var widened = a
    widened.pa.access = q.pa.access
    if covers(widened, q, localRuntime) and accessCovers(q.pa.access, a.pa.access):
      return Opt.some(a.pa.access)
  Opt.none(Opt[RouteAccess])

proc allowedProviders*(
    x: AuthzAnswer, request: EvaluateRequest, localRuntime: string
): Opt[Opt[seq[string]]] =
  ## [SPEC CA l.247-248; CAP-0041] For a discover allow: the providers it
  ## discloses (none inside: unconstrained); none when no allowed scope fits
  ## the operation in everything but its providers.
  if request.scopes.len != 1 or request.scopes[0].kind != skProvider:
    return Opt.none(Opt[seq[string]])
  let q = request.scopes[0]
  for a in x.allowedScopes:
    if a.kind != skProvider:
      continue
    var widened = a
    widened.pa.providers = q.pa.providers
    if covers(widened, q, localRuntime):
      if a.pa.providers.isNone:
        return Opt.some(Opt.none(seq[string]))
      var ids: seq[string]
      for p in a.pa.providers.get:
        if p.runtime_instance_id.isNone or p.runtime_instance_id.get == localRuntime:
          ids.add(p.provider)
      return Opt.some(Opt.some(ids))
  Opt.none(Opt[seq[string]])

func toRcAccess*(a: Opt[RouteAccess]): LogosNSRuntimeControlRouteAccess =
  if a.isNone:
    return LogosNSRuntimeControlRouteAccess()
  LogosNSRuntimeControlRouteAccess(
    methods: a.get.methods,
    publish_events: a.get.publish_events,
    subscribe_events: a.get.subscribe_events,
  )

# The engine's view (plain values only) ---------------------------------------------------

proc narrowedFor*(
    x: AuthzAnswer, request: openArray[byte], localRuntime: string
): bool =
  ## [CAP-0115, CAP-0051] Whether an allow excludes the operation it answered:
  ## an establish-route allow may narrow the access, which becomes the
  ## route's, and a discover allow the providers, which filter the
  ## candidates; any other narrowing excludes it.
  if x.outcome != azAllow:
    return false
  let r = EvaluateRequest.decode(request).valueOr:
    return true
  case x.request.action
  of aaRoute:
    if x.request.operation == "establish_route":
      x.allowedAccess(r, localRuntime).isNone
    else:
      not x.fits(r, localRuntime)
  of aaDiscover:
    x.allowedProviders(r, localRuntime).isNone
  else:
    not x.fits(r, localRuntime)

proc routeAccessOf*(
    x: AuthzAnswer, request: openArray[byte], localRuntime: string
): Opt[LogosNSRuntimeControlRouteAccess] =
  ## [RUN-0567] The access an establish-route allow gives the route.
  let r = EvaluateRequest.decode(request).valueOr:
    return Opt.none(LogosNSRuntimeControlRouteAccess)
  let a = x.allowedAccess(r, localRuntime)
  if a.isNone:
    return Opt.none(LogosNSRuntimeControlRouteAccess)
  Opt.some(toRcAccess(a.get))

proc providersOf*(
    x: AuthzAnswer, request: openArray[byte], localRuntime: string
): Opt[seq[string]] =
  ## [CAP-0041] The providers a discover allow discloses; none: every one.
  let r = EvaluateRequest.decode(request).valueOr:
    return Opt.some(newSeq[string]())
  let p = x.allowedProviders(r, localRuntime)
  if p.isNone:
    return Opt.some(newSeq[string]())
  p.get

const AuthorityModule* = "logos_capability_authority"
  ## [SPEC CA l.143] The Capability Authority's module name; the test suites
  ## check it against the name generated from the mirrored contract.

proc caRoots*(): tuple[contract, evaluate, grantChanged, policyChanged: seq[byte]] =
  ## [SPEC RUNTIME l.1652-1667; CAP-0089] The pinned Capability Authority
  ## contract and the declaration roots the binding needs, recomputed from the
  ## mirrored contract.
  (
    caContract().schema_root,
    caMethodRoot("evaluate"),
    caEventRoot("grant_changed"),
    caEventRoot("policy_changed"),
  )

type
  NoticeKind* = enum
    nkGrant
    nkPolicy

  Notice* = object
    kind*: NoticeKind
    grant*: string ## nkGrant
    ended*: bool ## nkGrant: the grant is revoked or expired
    expired*: bool ## nkGrant: expired rather than revoked
    previous*, revision*: uint64 ## nkPolicy
    affected*: Opt[seq[string]]
      ## nkPolicy: the local instances `affected_executions` lists; none when
      ## the event omits it
    foreign*: bool ## nkPolicy: `affected_executions` names another Runtime

proc readNotice*(
    name: string, payload: openArray[byte], localRuntime: string
): Result[Notice, string] =
  ## [SPEC CA §8 l.884-903] One `grant_changed` or `policy_changed` payload.
  if name == GrantChangedName:
    let e = GrantChanged.decode(payload).valueOr:
      return err("a grant_changed payload does not decode: " & error)
    let k = e.grant.status.kind
    return ok(
      Notice(
        kind: nkGrant,
        grant: e.grant.grant_id,
        ended: k != GrantStatusKind.Active,
        expired: k == GrantStatusKind.Expired,
      )
    )
  if name == PolicyChangedName:
    let e = LogosNSCapabilityAuthorityPolicyChangedEvent.decode(payload).valueOr:
      return err("a policy_changed payload does not decode: " & error)
    var n = Notice(
      kind: nkPolicy, previous: e.previous_policy_revision, revision: e.policy_revision
    )
    if e.affected_executions.isSome:
      var ids: seq[string]
      for a in e.affected_executions.get:
        if a.runtime_instance_id == localRuntime:
          ids.add(a.module_instance_id)
        else:
          n.foreign = true
      n.affected = Opt.some(ids)
    return ok(n)
  err("not a notice: " & name)
