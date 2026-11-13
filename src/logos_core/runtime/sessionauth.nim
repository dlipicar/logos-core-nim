## TRANSPORT §8.1, §8.1.1; RUNTIME §9.3 l.2073-2079, l.3004, l.3170-3183,
## l.3471-3484; DECISIONS I90, G255: the Runtime's ticket authority for
## transported local routes (plan §2.4).
##
## The store is the engine's `TicketStore[RouteBinding]`, on the Runtime thread
## and in memory only (TRANSPORT l.1036-1037): records hold a ticket's BLAKE3
## digest, never the ticket. A successful `establish_route` or `renew_route` of
## a transported route issues one ticket, which only that answer carries, in
## the route record's `invocation` (the live answer). Everything else sees the
## record without it: `list_routes`, events, describe, retained answers (so a
## `request_key` replay returns no ticket: G255, decision 12), records and
## diagnostics (RUN-0543, RUN-0544, CAP-0257).

{.push raises: [].}

import results
import ../hash/hashinput
import ../transport/[hello, ticket]
import ./routes

export ticket

func roots(x: Opt[seq[seq[byte]]]): Opt[seq[Digest]] =
  if x.isNone:
    return Opt.none(seq[Digest])
  var r: seq[Digest]
  for b in x.get:
    let d = toDigest(b)
    if d.isSome:
      r.add(d.get)
  Opt.some(r)

func accessRoots*(a: LogosNSRuntimeControlRouteAccess): RouteAccess =
  ## [SPEC TRANSPORT §8.1 l.969-979; RUNTIME §9.3 l.3013-3029] The route's
  ## access as the session enforces it: declaration subtree roots, none for a
  ## whole list. The roots were checked at establishment.
  RouteAccess(
    methods: roots(a.methods),
    publishEvents: roots(a.publish_events),
    subscribeEvents: roots(a.subscribe_events),
  )

func bindingOf*(r: Route, endpoint, module: string): RouteBinding =
  ## [SPEC TRANSPORT §8.1] What a ticket for `r` binds a session to: consumer,
  ## provider, selected contract, the endpoint path, the route, its access,
  ## its decision and its end on the engine's monotonic clock. A local route
  ## has no source Runtime. [IMPL-DECISION G257] The provider is bound as the
  ## flat module name the Hello carries (TRANSPORT §3.1 l.451); the
  ## provider instance and realization are bound by the endpoint, one per
  ## realization, and by the route.
  RouteBinding(
    consumer: r.consumer,
    provider: module,
    contract: r.selected.root,
    endpoint: endpoint,
    route: r.id,
    access: accessRoots(r.access),
    decision: r.decisionId,
    expires: r.monoDeadline,
    validUntil:
      if r.expiresAt.isSome:
        Opt.some(int64(r.expiresAt.get))
      else:
        Opt.none(int64),
  )

proc issueFor*(
    store: var TicketStore[RouteBinding],
    r: Route,
    endpoint, module: string,
    now: Nanos,
    rng: RandomSource = osRandom,
): Result[RouteTicket, string] =
  ## [SPEC TRANSPORT §8.1.1 l.1031-1047] A fresh ticket for `r`: it expires
  ## with the route and at most 60 s after `now`; a collision is redrawn.
  ## Renewal issues a fresh one and never reissues; an earlier unused one is
  ## left to expire [IMPL].
  store.issue(bindingOf(r, endpoint, module), now, r.monoDeadline.get(high(int64)), rng)

func descriptor*(
    path: string, t: RouteTicket
): LogosNSRuntimeControlInvocationDescriptor =
  ## [SPEC RUNTIME l.2073-2079] The `local-transport` invocation descriptor;
  ## its kind and profile literals are the generated defaults.
  LogosNSRuntimeControlInvocationDescriptor(
    kind: LogosNSRuntimeControlInvocationDescriptorKind.Case0,
    arm_0: LogosNSRuntimeControlInvocationDescriptorAR0Map(path: path, ticket: @t),
  )

func live*(
    rec: LogosNSRuntimeControlRouteRecord, path: string, t: RouteTicket
): LogosNSRuntimeControlRouteRecord =
  ## The record of a live answer: `rec` with its `invocation`.
  result = rec
  result.invocation = Opt.some(descriptor(path, t))

proc revokeRoute*(store: var TicketStore[RouteBinding], route: string): int =
  ## [SPEC TRANSPORT §8.1.1; plan §2.4] Every live ticket of `route`, at any
  ## terminal transition.
  store.revoke(
    proc(b: RouteBinding): bool =
      b.route == route
  )

func nextExpiry*(store: TicketStore[RouteBinding]): Opt[Nanos] =
  ## [Rev R17] The earliest record expiry, for the engine's next deadline.
  store.earliest()
