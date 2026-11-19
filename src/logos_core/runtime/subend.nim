## INTERFACE §2.5 l.1472-1485, §5.2: the one `observe_subscription_end`
## registration a Runtime Control binding or a route handle holds, and its
## reports.
##
## [DECISIONS G225] The slot keeps the registration, whether reports are
## suppressed, and how many are running; who runs a report is the embedder's
## (the engine on a Runtime event worker, the Module Host on its own workers).
## An end is reported only when a registration is installed at the moment of
## the end (l.1481, `owed`); the report job then runs the handler once
## (`report`) unless release or destroy suppressed it first (`suppress`), and
## the embedder waits for a running one (`busy`) under its own lock.
##
## The registration rules are `observe_end`'s (l.1477, and l.1452, l.1459 by
## I105's reading): a null handler and a second registration are
## INVALID_PARAMS, a refused registration keeps nothing, and a route handle
## that is already terminal returns its retained code before it gets here
## (`bindings`, `host/consumer`).

{.push raises: [], gcsafe.}

import std/atomics
import logos_sdk/abi/[cstatus, types]
import logos_sdk/iface/outcome

type SubscriptionEndSlot* = object
  ## Zero-initialized: no registration. A slot lives as long as its binding or
  ## handle and is never moved.
  state: Atomic[int] ## 0 none, 1 being installed, 2 installed, 3 suppressed
  handler: LogosSubscriptionEndHandler
  userData: pointer
  running: Atomic[int] ## reports begun and not returned

proc register*(
    s: var SubscriptionEndSlot, handler: LogosSubscriptionEndHandler, userData: pointer
): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1477] One non-null handler per binding or handle,
  ## never invoked on the registering thread: a null handler or a second
  ## registration is INVALID_PARAMS. A slot per binding cannot run out, so the
  ## capacity failure (MODULE_ERROR) does not arise.
  if handler.isNil:
    return status(ecInvalidParams, "a null subscription-end handler")
  var none = 0
  if not s.state.compareExchange(none, 1):
    return status(ecInvalidParams, "a subscription-end handler is already registered")
  s.handler = handler
  s.userData = userData
  s.state.store(2)
  LogosResult()

proc installed*(s: var SubscriptionEndSlot): bool =
  ## Whether a handler is registered and its reports are not suppressed.
  s.state.load == 2

proc owed*(s: var SubscriptionEndSlot): bool =
  ## [SPEC INTERFACE l.1481] At an end: whether it is reported. An end while
  ## no registration is installed is not reported later.
  s.installed

proc report*(
    s: var SubscriptionEndSlot, id: LogosSubscriptionId, reason: ErrorCode
): bool =
  ## [SPEC INTERFACE l.1478-1479, l.1484] A report job: the handler once, with
  ## the subscription id and a nonzero reason, unless the slot was suppressed
  ## before it began; true when it ran. The count is taken before the check,
  ## so `suppress` followed by `busy` never misses a report that began.
  discard s.running.fetchAdd(1)
  if s.state.load == 2:
    s.handler(id, CErrorCode(ord(reason)), s.userData)
    result = true
  discard s.running.fetchSub(1)

proc suppress*(s: var SubscriptionEndSlot) =
  ## [SPEC INTERFACE l.1484, l.1954] Release or destroy: no report begins
  ## after this. The caller then waits while `busy`.
  s.state.store(3)

proc busy*(s: var SubscriptionEndSlot): bool =
  ## A report is running.
  s.running.load > 0
