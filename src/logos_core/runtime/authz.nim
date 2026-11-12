## RUNTIME §9 authority policy: one authorizer interface at every check point
## the spec names [G52].
##
## Every check asks `decide` with the operation, the authenticated consumer and
## the target, and gets an allow or deny answer with a decision identifier and
## the scope it covered. The engine keeps the most recent answers, so allow and
## deny enforcement can be explained (RUNTIME l.1756-1760), and keeps an
## evaluation failure apart from an explicit deny (l.1740-1744).
##
## Until the Capability Authority is integrated the policy is internal, which
## RUNTIME permits for a local trusted deployment (l.1633-1634): allow-all,
## optionally with rules that deny or fail matching requests, so the tests
## reach every NOT_AUTHORISED path. A policy is data, not code: it is handed to
## the Runtime thread like any other input.

{.push raises: [].}

import std/deques
import results

export results

const MaxRetainedAnswers* = 4096
  ## [IMPL] answers kept for observation; older ones are dropped first

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

  AuthzRequest* = object
    action*: AuthzAction
    operation*: string ## the method or operation name, such as `start_module`
    consumer*: string ## the authenticated consumer instance; empty for the host
    target*: string ## the target instance, provider or route
    module*: string ## the target's module name, when known
    route*: string ## the route the request concerns, when there is one

  AuthzOutcome* = enum
    azAllow = "allow"
    azDeny = "deny" ## an explicit deny result from policy
    azEvaluationFailed = "evaluation-failed" ## no valid decision was obtained

  AuthzAnswer* = object
    decisionId*: string
    outcome*: AuthzOutcome
    scope*: string ## what the decision covered
    request*: AuthzRequest

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

func initAuthorizer*(policy: AuthzPolicy): Authorizer =
  Authorizer(policy: policy)

func matches(r: AuthzRule, q: AuthzRequest): bool =
  (r.action.isNone or r.action.get == q.action) and
    (r.operation.len == 0 or r.operation == q.operation) and
    (r.consumer.len == 0 or r.consumer == q.consumer) and
    (r.target.len == 0 or r.target == q.target) and
    (r.module.len == 0 or r.module == q.module) and
    (r.route.len == 0 or r.route == q.route)

func scopeOf(q: AuthzRequest): string =
  ## [IMPL] An internal decision covers exactly the one request it answered.
  $q.action & ":" & q.operation & ":" & q.consumer & ">" & q.target

proc decide*(a: var Authorizer, q: AuthzRequest): AuthzAnswer =
  inc a.issued
  var outcome = azAllow
  for r in a.policy.rules:
    if r.matches(q):
      outcome = r.outcome
      break
  result = AuthzAnswer(
    decisionId: "d-" & $a.issued, outcome: outcome, scope: q.scopeOf, request: q
  )
  if a.answers.len >= MaxRetainedAnswers:
    a.answers.popFirst()
  a.answers.addLast(result)

func answers*(a: Authorizer): seq[AuthzAnswer] =
  for x in a.answers:
    result.add(x)
