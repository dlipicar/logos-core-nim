## INTERFACE §2.5 l.1476-1484, §5.2: the one `observe_subscription_end`
## registration a Runtime Control binding or a route handle holds.
##
## [DECISIONS I105, interim until re-pin P3] Registration only: nothing ends a
## subscription for the binding yet, so the handler is installed and never
## invoked. P3 adds the reporting and its suppression at release.
##
## The rules are `observe_end`'s (l.1477, and l.1452, l.1459 by I105's
## reading): a null handler and a second registration are INVALID_PARAMS, a
## refused registration keeps nothing, and a route handle that is already
## terminal returns its retained code before it gets here (`bindings`,
## `host/consumer`).

{.push raises: [], gcsafe.}

import std/atomics
import logos_sdk/abi/[cstatus, types]
import logos_sdk/iface/outcome

type SubscriptionEndSlot* = object
  ## Zero-initialized: no registration. A slot lives as long as its binding or
  ## handle and is never moved.
  state: Atomic[int] ## 0 none, 1 being installed, 2 installed
  handler: LogosSubscriptionEndHandler
  userData: pointer

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
  ## Whether a handler is registered (tests; P3's reporting reads it).
  s.state.load == 2
