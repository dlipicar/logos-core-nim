## INTERFACE §2.5 l.1472-1485, §5.2: the one `observe_subscription_end`
## registration a Runtime Control binding or a route handle holds, and its
## reports.
##
## [DECISIONS G225] The slot keeps the registration, whether reports are
## suppressed, and how many are running, in one atomic word; who runs a
## report is the embedder's (the engine on a Runtime event worker, the Module
## Host on its own workers). An end is reported only when a registration is
## installed at the moment of the end (l.1481, `owed`); the report job then
## runs the handler once (`report`) unless release or destroy suppressed it
## first (`suppress`), and the embedder waits for a running one (`busy`)
## under its own lock. A report has begun once its compare-and-set found the
## slot installed and counted it (l.1954: "has not begun" is exact).
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

const
  StateBits = 3 ## the word's low bits: the registration's state
  Installing = 1
  Installed = 2
  Suppressed = 3
  Running = 4 ## one report begun and not returned, above the state bits

type SubscriptionEndSlot* = object
  ## Zero-initialized: no registration. A slot lives as long as its binding or
  ## handle and is never moved.
  word: Atomic[int]
    ## the state (0 none, `Installing`, `Installed`, `Suppressed`) plus
    ## `Running` per report begun and not returned
  handler: LogosSubscriptionEndHandler
  userData: pointer

proc register*(
    s: var SubscriptionEndSlot, handler: LogosSubscriptionEndHandler, userData: pointer
): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1477] One non-null handler per binding or handle,
  ## never invoked on the registering thread: a null handler or a second
  ## registration is INVALID_PARAMS. A slot per binding cannot run out, so the
  ## capacity failure (MODULE_ERROR) does not arise. A suppression that comes
  ## while the handler is being stored stays.
  if handler.isNil:
    return status(ecInvalidParams, "a null subscription-end handler")
  var none = 0
  if not s.word.compareExchange(none, Installing):
    return status(ecInvalidParams, "a subscription-end handler is already registered")
  s.handler = handler
  s.userData = userData
  var installing = Installing
  discard s.word.compareExchange(installing, Installed)
  LogosResult()

proc installed*(s: var SubscriptionEndSlot): bool =
  ## Whether a handler is registered and its reports are not suppressed.
  (s.word.load and StateBits) == Installed

proc owed*(s: var SubscriptionEndSlot): bool =
  ## [SPEC INTERFACE l.1481] At an end: whether it is reported. An end while
  ## no registration is installed is not reported later.
  s.installed

proc report*(
    s: var SubscriptionEndSlot, id: LogosSubscriptionId, reason: ErrorCode
): bool =
  ## [SPEC INTERFACE l.1478-1479, l.1484, l.1954] A report job: the handler
  ## once, with the subscription id and a nonzero reason, unless the slot was
  ## suppressed before it began; true when it ran. It begins with one
  ## compare-and-set that finds the slot installed and counts it running, so
  ## `suppress` followed by `busy` never misses a report that began.
  var v = s.word.load
  while true:
    if (v and StateBits) != Installed:
      return false
    if s.word.compareExchange(v, v + Running):
      break
  s.handler(id, CErrorCode(ord(reason)), s.userData)
  discard s.word.fetchSub(Running)
  true

when defined(lcnTestHooks):
  proc handlerKeyForTests*(s: var SubscriptionEndSlot): pointer =
    ## [DECISIONS G466] Test hook: the handler a report would run, or nil when
    ## none is installed or the slot is suppressed.
    if (s.word.load and StateBits) == Installed:
      cast[pointer](s.handler)
    else:
      nil

proc suppress*(s: var SubscriptionEndSlot) =
  ## [SPEC INTERFACE l.1484, l.1954] Release or destroy: no report begins
  ## after this. The caller then waits while `busy`.
  discard s.word.fetchOr(Suppressed)

proc busy*(s: var SubscriptionEndSlot): bool =
  ## A report is running.
  s.word.load >= Running
