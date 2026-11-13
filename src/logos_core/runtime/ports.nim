## DECISIONS I90; 4b-2 plan §2.1 [Rev R11]: the ports between the Runtime and
## the two movable halves of a transported route.
##
## The provider boundary (`served.nim`) and the caller binding
## (`transported.nim`) never touch the engine's state. They see the Runtime
## only through these ports, so 4b-3 can move either into a Module Host and
## carry the same operations over the host carrier.
##
## `IoPort` (`tport.nim`): `submit`, `trySubmit`, `submitOwner`, `submitWait`,
## `newConnId`, `ensureStarted` on the process's one loop.
##
## `WorkPort`: the engine's call workers (served invocations, as `AsyncCall`s
## with a session origin) and the G178 event workers.
##
## `SessionAuthority` (the halves ask; the Runtime decides). In 4b-2 the
## engine answers in process, on the Runtime thread:
##
## | Operation | 4b-2 | Answers |
## |---|---|---|
## | `hello` | `engine.hello` → `hello.acceptHello` with a `HelloCheck` | state checks, then redemption |
## | `admitCall` | `engine.servedDispatch` → `admit` | a refusal, or a `CallRef` |
## | `callEnded` | `asynccall` commit, then `engine.maybeForget` → `served.callEnded` | the record, the slot |
## | `subscribe` / `unsubscribe` | `engine.servedSubscribe` → `servedActivate` on a call worker (`cjActivate`); `engine.servedUnsubscribe` | the activation decision, recorded on the session before the SubscriptionResult (R7) |
## | `deliver`, `scopedPublish` | `engine.deliverConn` (`rqDeliverConn`), `engine.scopedConn` and `publishVerdict` | the G175 decisions; a subscriber's deny skips one Event (K40); the E2 verdict's code |
## | `sessionEnded` | `engine.servedClosed` | each open call ends CANCELLED |
## | `materializeFailed` | `engine.linkConnectFailed` (`transported.connectOutcome`) | fails the route (K12) |
##
## `EndpointOrders` (the Runtime orders the provider half): `served.stopServing`,
## `served.terminate`, `served.drain`, `served.close`. Which one a route end
## gives a session, and the bound of a drain, is that end's row of
## `EndPolicies`.
##
## `LinkOrders` (the Runtime orders the caller half): `routeEnded(link,
## cause)`, recording the cause first (K13, R3): `engine.linksEnded` in 4b-2b,
## where the caller half also runs on the Runtime thread; `engine.linksStopped`
## at the engine's end. Ending a link also ends its subscriptions
## (`engine.endLinkSubs`): queued Events are discarded and their credits
## released (TRN-0290).

{.push raises: [], gcsafe.}

type
  CallRef* = pointer
    ## An admitted served invocation, opaque to the provider half: in 4b-2 an
    ## `asynccall.AsyncCall`; in a host, the host's own served call.

  SessionOrder* = enum
    soTerminate ## NOT_AUTHORISED to each in-flight Request, ProtocolError, close
    soDrain ## admit nothing new; close once admitted calls answered, or at the deadline
    soClose ## close at once, no ProtocolError

  RouteEnd* = enum
    ## What ended a transported route, as its sessions see it.
    reRevoked ## revocation, a G216 deny or narrowing, a failed evaluation
    reExpired ## the route's decision expired
    reTransport ## the transport failed: a serve failure, K12's peer mismatch
    reNoSession ## its establishment failed (no ticket issued): it never had a session
    reSideGone ## [4b-3] the failed side's process or host is gone
    reCloseRoute ## `close_route`
    reProviderStop ## the provider stops, an execution-authority stop included
    reShutdown ## the Runtime shuts down
    reConsumerStop ## the consumer stops
    reConsumerFailure ## the consumer failed
    reProviderFailure ## the provider failed

  DrainBound* = enum
    ## How long a draining session may still answer what it admitted.
    dbNone ## it does not drain
    dbProviderStop ## the provider's stop deadline
    dbConsumerStop ## the consumer's stop deadline
    dbShutdownGrace ## the shutdown grace
    dbFromEnd ## `stop_deadline` from the route's end [IMPL]
    dbCleanup
      ## the drain deadline of the failed instance's cleanup release. [IMPL]
      ## That release has no deadline of its own in this engine: a direct
      ## realization is never force-released (RUNTIME l.3838), and its
      ## `_MODULE_destroy` waits for the calls inside it (l.623). So it is
      ## `stop_deadline` from the route's end, the bound an explicit stop gives
      ## its own cleanup.

  EndPolicy* = object
    order*: SessionOrder
    bound*: DrainBound

# [G260; G174 (a); owner batch B 7] What each end of a transported route
# orders its sessions, one row per end.
#
# An authority end terminates (TRANSPORT l.987-991). An end that leaves no
# usable session closes at once: a transport failure, a serve failure and K12
# (TRANSPORT l.543). Every readiness end drains. Batch B 7 named the
# provider stop, shutdown and `close_route`. Fable's reading (2026-11-13)
# adds the consumer's stop and failure and the provider's failure, as our
# choice within G174 (a) (RUNTIME l.623, l.1065, l.3226-3227, l.3850). It
# sets three conditions:
# - drain only while the session is intact: a side whose process or host is
#   gone closes at once (`reSideGone`, TRANSPORT l.543);
# - every in-flight invocation is still marked cancelled at the route's end
#   and its provider notified (INTERFACE l.2101), which `endRoute` does for
#   every end, so a provider can finish early; a result that arrives within
#   the bound is still delivered;
# - nothing waits past the bound.
# For every end, admission closes at once (RUNTIME l.3224, and l.621 for the
# consumer's new outbound calls).
const EndPolicies*: array[RouteEnd, EndPolicy] = [
  reRevoked: EndPolicy(order: soTerminate, bound: dbNone),
  reExpired: EndPolicy(order: soTerminate, bound: dbNone),
  reTransport: EndPolicy(order: soClose, bound: dbNone),
  reNoSession: EndPolicy(order: soClose, bound: dbNone),
  reSideGone: EndPolicy(order: soClose, bound: dbNone),
  reCloseRoute: EndPolicy(order: soDrain, bound: dbFromEnd),
  reProviderStop: EndPolicy(order: soDrain, bound: dbProviderStop),
  reShutdown: EndPolicy(order: soDrain, bound: dbShutdownGrace),
  reConsumerStop: EndPolicy(order: soDrain, bound: dbConsumerStop),
  reConsumerFailure: EndPolicy(order: soDrain, bound: dbCleanup),
  reProviderFailure: EndPolicy(order: soDrain, bound: dbCleanup),
]

static:
  for p in EndPolicies:
    # A drain has a bound, and nothing else has one.
    doAssert (p.order == soDrain) == (p.bound != dbNone)
