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
## | `subscribe` / `unsubscribe` | 4b-2b | the activation decision (R7) |
## | `deliver`, `scopedPublish` | 4b-2b | the G175 decisions |
## | `sessionEnded` | `engine.servedClosed` | each open call ends CANCELLED |
## | `materializeFailed` | 4b-2b | fails the route (K12) |
##
## `EndpointOrders` (the Runtime orders the provider half): `served.stopServing`,
## `served.terminate`, `served.drain`, `served.close`; which one a route end
## gives a session is `sessionOrder`.
##
## `LinkOrders` (the Runtime orders the caller half): `routeEnded(link,
## cause)`, recording the cause first (K13, R3); 4b-2b.

{.push raises: [], gcsafe.}

import results
import ../iface/outcome
from ./routes import RouteFailureCode

type
  CallRef* = pointer
    ## An admitted served invocation, opaque to the provider half: in 4b-2 an
    ## `asynccall.AsyncCall`; in a host, the host's own served call.

  SessionOrder* = enum
    soTerminate ## NOT_AUTHORISED to each in-flight Request, ProtocolError, close
    soDrain ## admit nothing new; close once admitted calls answered, or at the deadline
    soClose ## close at once, no ProtocolError

func sessionOrder*(endCode: ErrorCode, failure: Opt[RouteFailureCode]): SessionOrder =
  ## [plan §2.8; owner batch B 7, K13] What a route end orders each of its
  ## sessions: an authority end (revocation, expiry) terminates (TRANSPORT
  ## l.987-991); a transport failure closes; any readiness end (provider stop,
  ## shutdown, close_route, a consumer or provider failure) drains, bounded by
  ## the stop deadline.
  if endCode == ecNotAuthorised:
    soTerminate
  elif failure == Opt.some(rfTransportError):
    soClose
  else:
    soDrain
