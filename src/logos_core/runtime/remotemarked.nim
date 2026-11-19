## The marked-method refusal of the remote profiles (re-pin P4d; RUNTIME
## §9.3.1 l.1808, §9.3 l.2939; TRANSPORT §8.4 l.1188-1189; DECISIONS G277).
##
## `logos.remote.tls-tcp` and `logos.remote.quic` carry no payload that
## `_sensitive` marks: the TLS library keeps decrypted records in buffers it
## releases unerased (G327). A route on either profile whose permitted method
## scope includes a marked method is refused with `INVALID_PARAMS` without
## detail (l.1808), by `establish_route` and `renew_route` before a ticket is
## issued or a ready route published (l.2939), and no ordinary provider session
## is established for it (TRANSPORT l.1188). Another remote profile may carry
## marked payloads when it meets INTERFACE §1.4.1 (TRANSPORT l.1189).
##
## Its place in the order of checks (RUNTIME l.1824-1833; G171) is the third
## row of the precondition table, after the route decision has narrowed the
## scope and before readiness: for `establish_route` the key, the decisions,
## this check, readiness. The caller passes the route access the decision left
## (RG-6), so a scope that authority narrowed to unmarked methods passes.
##
## Nothing calls it yet: a route is `direct` or `local-transport`
## (`routing.RouteMode`), and the engine's `erases` refuses any other kind of
## path for a contract that marks a payload (G277). Step 5-7a calls it from
## `establish_route`, `renew_route` and provider session setup, where the
## remote route kind is built (RUN-1163 and TRN-0398 are deferred to it).

{.push raises: [].}

import std/tables
import results
import logos_sdk/kit/rc_types
import ./[rcaddress, routes]

func withoutMarked*(profile: string): bool =
  ## [SPEC TRANSPORT l.1188-1189] Whether `profile` is a remote profile that
  ## carries no marked payload. Any other profile may, when it meets INTERFACE
  ## §1.4.1.
  profile == RemoteTlsTcp or profile == RemoteQuic

func refusesMarked*(
    profile: string,
    access: LogosNSRuntimeControlRouteAccess,
    contract: SelectedContract,
): bool =
  ## [SPEC RUNTIME l.1808, l.2939; TRANSPORT l.1188] True when a route on
  ## `profile` with the permitted scope `access` (after authority narrowed it)
  ## would permit a method of `contract` whose request or response is marked.
  ## An absent method list permits every method of the contract and
  ## `logos.schema` (l.2935), which is never marked; an empty one permits none.
  ## The events lists do not matter: only method payloads are marked
  ## (INTERFACE §1.2.1).
  if not withoutMarked(profile):
    return false
  for bare, side in contract.sensitive:
    if not (side.request or side.response) or bare notin contract.methods:
      continue
    if access.methods.isNone:
      return true
    let root = Opt.some(contract.methods.getOrDefault(bare))
    for item in access.methods.get:
      if toDigest(item) == root:
        return true
  false
