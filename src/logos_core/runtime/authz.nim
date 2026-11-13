## RUNTIME §9 authority policy: one authorizer interface at every check point
## the spec names [G52].
##
## Every check builds an `AuthzRequest` with the operation, the authenticated
## consumer and the target, and gets an allow or deny answer with a decision
## identifier and the scope it covered. The engine keeps the most recent
## answers, so allow and deny enforcement can be explained (RUNTIME
## l.1756-1760), and keeps an evaluation failure apart from an explicit deny
## (l.1740-1744).
##
## Where an answer comes from is its `PolicySource` (step 8b, DECISIONS I85):
## - `psInternal`: the host configuration's `allow-all`, which RUNTIME permits
##   for a local trusted deployment (l.1633-1634), optionally with rules that
##   deny or fail matching requests, so the tests reach every NOT_AUTHORISED
##   path. A policy is data, not code: it is handed to the Runtime thread like
##   any other input.
## - `psBootstrap`, `psRecovery`: the derived rules of protected input while
##   no Capability Authority binding exists (`engine.nim`, RUNTIME l.1635-1650,
##   l.1674-1680).
## - `psAuthority`: a Capability Authority decision (`authbinding.nim`). Its
##   denial and error codes are retained and never branched on (TL-04).
##
## This module holds the values and the internal authorizer. The engine
## decides which source answers a request.

{.push raises: [].}

import std/deques
import results

export results

const
  MaxRetainedAnswers* = 4096
    ## [IMPL] answers kept for observation; older ones are dropped first
  GrantChangedName* = "logos.capability_authority.grant_changed_event"
    ## [SPEC CA §8] the notices the Runtime receives on its protected path
  PolicyChangedName* = "logos.capability_authority.policy_changed_event"

type
  AuthzAction* = enum
    ## The kinds of check (RUNTIME l.1636-1650, l.715, l.1732).
    aaRuntimeControl = "runtime-control" ## a Runtime Control method
    aaLifecycle = "lifecycle" ## starting, stopping or controlling a module
    aaExecute = "execute" ## execution authorization before realization (§3.6)
    aaRoute = "route" ## establishing, renewing or revoking a route
    aaCall = "call" ## an ordinary provider method call
    aaPublishEvent = "publish-event"
      ## [G175] delivering a publisher's event on one subscriber route: the
      ## consumer is the publisher, the target the subscriber (CA l.236-245)
    aaSubscribeEvent = "subscribe-event"
      ## [G175] a subscriber activating or receiving an event on its route
    aaDiscover = "discover" ## disclosing a provider set
    aaObserve = "observe" ## observing Runtime-owned state
    aaObserveEvent = "observe-event"
      ## [G161 extension (TF-09); I86] observing Runtime-owned state through
      ## a Runtime Control event: `operation` is its bare name without
      ## `_event`, the consumer the subscriber
    aaStop = "stop"
      ## [SPEC CA l.335] the `module_execution` `stop` constraint of a
      ## `stop_module`, decided with that request's `aaLifecycle`

  PolicySource* = enum
    psInternal = "internal" ## host config `allow-all`, or the test rules
    psBootstrap = "bootstrap"
      ## the derived rules of protected input before the first binding
    psRecovery = "recovery" ## the same rules after a binding loss, when enabled
    psAuthority = "authority" ## a Capability Authority decision
    psBoundary = "boundary"
      ## [S8b-1 interim (TF-31)] the Runtime's own check of a routed call to a
      ## Capability Authority method, after the call was authorized

  AuthzRequest* = object
    action*: AuthzAction
    operation*: string
      ## the Runtime Control method, or the method or event name, such as
      ## `start_module`
    consumer*: string ## the authenticated consumer instance; empty for the host
    target*: string ## the target instance, provider or route
    module*: string ## the target's module name, when known
    route*: string ## the route the request concerns, when there is one
    instance*: string
      ## the target module instance, when the target is one (lifecycle,
      ## observation, execution)
    provider*: string ## the provider record, when the request concerns one
    contract*: seq[byte] ## the selected or requested contract root, when any
    declaration*: seq[byte] ## the method or event declaration root, when any
    access*: seq[byte]
      ## the requested route access as deterministic CBOR
      ## (`logos.runtime_control.route_access`); empty when unconstrained
    providerSelector*: bool
      ## a lifecycle or observation request that selects by provider address
    renewal*: bool
      ## [SPEC CA §5.1 l.577-578] an execution decision asked again for an
      ## execution that is already running (`execution_renewal`)
    filters*: bool
      ## [IMPL; G161 extension, I86] an observation of many subjects (a list
      ## method, a Runtime Control event): it names no subject, and a
      ## narrowed allow filters the subjects it observes instead of excluding
      ## the operation (RUNTIME l.3373, CA l.565-567)

  AuthzOutcome* = enum
    azAllow = "allow"
    azDeny = "deny" ## an explicit deny result from policy
    azEvaluationFailed = "evaluation-failed" ## no valid decision was obtained
    azRefused = "refused"
      ## [S8b-1 interim (TF-31)] refused at the invocation boundary: neither a
      ## deny nor an evaluation failure (RUNTIME l.1745-1748)

  AuthzAnswer* = object
    decisionId*: string
    outcome*: AuthzOutcome
    source*: PolicySource
    scope*: string ## what the decision covered
    request*: AuthzRequest
    policyRevision*: uint64 ## psAuthority only
    issuedAt*: uint64 ## psAuthority only: wall-clock milliseconds
    validUntil*: Opt[uint64] ## psAuthority only: wall-clock milliseconds
    grants*: seq[string] ## psAuthority only: the grants the decision used
    retainRequest*, retainResponse*: bool ## the decision's `commitment`
    allowed*: seq[seq[byte]]
      ## psAuthority allows: each of `allowed_scopes` as deterministic CBOR,
      ## for enforcement and call records
    narrowed*: bool
      ## [IMPL] an allow whose narrowing excludes the operation: refused as
      ## NOT_AUTHORISED, neither a deny nor an evaluation failure (CAP-0115)
    denialCode*: string ## retained only (TL-04)
    errorCode*: string ## retained only (TL-04)
    reason*: string ## why an evaluation failed, for diagnostics only

  EvalVerdict* = enum
    evFailed ## no valid decision (`error` arm, dispatch failure, malformed)
    evAllow
    evDeny

  EvalResult* = object
    ## What an evaluation worker read from one `evaluate` and checked against
    ## its request (`authbinding.nim`); plain values only.
    verdict*: EvalVerdict
    decisionId*: string
    policyRevision*: uint64
    issuedAt*: uint64
    validUntil*: Opt[uint64]
    grants*: seq[string]
    retainRequest*, retainResponse*: bool
    allowed*: seq[seq[byte]]
    denialCode*, errorCode*, reason*: string

  AuthzRule* = object
    ## Matches a request when every non-empty field is equal; `action` matches
    ## when it is absent or equal.
    action*: Opt[AuthzAction]
    operation*: string
    consumer*: string
    target*: string
    module*: string
    route*: string
    outcome*: AuthzOutcome ## what a matching request gets

  AuthzPolicy* = object ## Allow-all, except what the first matching rule says.
    rules*: seq[AuthzRule]

  Authorizer* = object
    policy: AuthzPolicy
    prefix: string
    issued: uint64
    answers: Deque[AuthzAnswer]

func allowAll*(): AuthzPolicy =
  AuthzPolicy()

func denying*(rules: varargs[AuthzRule]): AuthzPolicy =
  ## The test authorizer: allow-all except the given rules.
  AuthzPolicy(rules: @rules)

func deny*(
    action = Opt.none(AuthzAction),
    operation = "",
    consumer = "",
    target = "",
    module = "",
    route = "",
    outcome = azDeny,
): AuthzRule =
  AuthzRule(
    action: action,
    operation: operation,
    consumer: consumer,
    target: target,
    module: module,
    route: route,
    outcome: outcome,
  )

func initAuthorizer*(policy: AuthzPolicy, prefix: string): Authorizer =
  ## [IMPL] Decision ids are `d-<prefix>-<n>`: the engine's random prefix keeps
  ## every run's ids apart from every earlier run's (CA l.548-550; I82).
  Authorizer(policy: policy, prefix: prefix)

func matches(r: AuthzRule, q: AuthzRequest): bool =
  (r.action.isNone or r.action.get == q.action) and
    (r.operation.len == 0 or r.operation == q.operation) and
    (r.consumer.len == 0 or r.consumer == q.consumer) and
    (r.target.len == 0 or r.target == q.target) and
    (r.module.len == 0 or r.module == q.module) and
    (r.route.len == 0 or r.route == q.route)

func scopeOf*(q: AuthzRequest): string =
  ## [IMPL] An internal decision covers exactly the one request it answered.
  $q.action & ":" & q.operation & ":" & q.consumer & ">" & q.target

func hexOf(b: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for x in b:
    result.add(digits[int(x shr 4)])
    result.add(digits[int(x and 0x0F)])

func key*(q: AuthzRequest): string =
  ## [IMPL] One operation's decisions are matched again by this key when its
  ## handler runs another pass (`engine.decide`).
  $q.action & "\x1F" & q.operation & "\x1F" & q.consumer & "\x1F" & q.target & "\x1F" &
    q.module & "\x1F" & q.route & "\x1F" & q.instance & "\x1F" & q.provider & "\x1F" &
    hexOf(q.contract) & "\x1F" & hexOf(q.declaration) & "\x1F" & hexOf(q.access) & "\x1F" &
    $q.providerSelector & "\x1F" & $q.renewal & "\x1F" & $q.filters

proc retain*(a: var Authorizer, answer: AuthzAnswer) =
  ## Keeps one answer for observation, the oldest dropped first.
  if a.answers.len >= MaxRetainedAnswers:
    a.answers.popFirst()
  a.answers.addLast(answer)

proc nextId*(a: var Authorizer): string =
  ## A fresh internal decision id.
  inc a.issued
  "d-" & a.prefix & "-" & $a.issued

proc issue*(
    a: var Authorizer,
    q: AuthzRequest,
    outcome: AuthzOutcome,
    source: PolicySource,
    reason = "",
): AuthzAnswer =
  ## An answer the Runtime makes itself (internal, bootstrap or recovery
  ## policy, or an evaluation that could not take place), with an internal
  ## decision id, retained.
  result = AuthzAnswer(
    decisionId: a.nextId(),
    outcome: outcome,
    source: source,
    scope: q.scopeOf,
    request: q,
    reason: reason,
  )
  a.retain(result)

proc decide*(a: var Authorizer, q: AuthzRequest): AuthzAnswer =
  ## The internal policy's answer: allow, unless a rule matches.
  var outcome = azAllow
  for r in a.policy.rules:
    if r.matches(q):
      outcome = r.outcome
      break
  a.issue(q, outcome, psInternal)

func permits*(a: Authorizer, q: AuthzRequest): bool =
  ## [IMPL; I86] What the internal policy would answer `q`, without issuing
  ## or retaining an answer: how an internal allow of an observation without
  ## a subject is applied to each subject it observes.
  for r in a.policy.rules:
    if r.matches(q):
      return r.outcome == azAllow
  true

func answers*(a: Authorizer): seq[AuthzAnswer] =
  for x in a.answers:
    result.add(x)

func allows*(x: AuthzAnswer): bool =
  ## The operation may proceed: an allow that does not exclude it.
  x.outcome == azAllow and not x.narrowed
