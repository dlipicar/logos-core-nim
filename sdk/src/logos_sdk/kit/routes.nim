## Routes and Runtime Control subscriptions for module code [IMPL] (DECISIONS
## G339; INTERFACE §2.5, §2.9, §5.2; RUNTIME §9.3).
##
## Module code imports this module; generated code never does. It reaches the
## Runtime Control types through `rcclient`, which a generated `_calls.nim`
## must not import (`tools/lint/layers.toml`, `kit_facade`).
##
## - A `RouteSet` belongs to one module instance and its Runtime Control
##   binding. It holds the route handles and prepared calls the instance gives
##   it, and its Runtime Control subscriptions, and `close` releases all of
##   them: in `_MODULE_destroy` (INTERFACE l.1959-1960), and before
##   `_MODULE_init` returns a failure (l.1607, l.3892). A handle or call the set
##   holds is released through the set, never directly.
## - `openRoute` establishes routes to one contract (`establish_route`, RUNTIME
##   §9.3), then materializes and wraps each returned route
##   (`consumert.wrapRoute`). Each route has its own outcome: a failed
##   materialization or wrap does not release the others. The `request_key` is
##   fresh unless the caller gives one, so a retry after a lost response can
##   replay the result (R l.3072-3080). A replayed route record has no
##   invocation (R l.3080): `renewRoute` it, then `materialize` it.
## - `renewRoute` and `closeRoute` act on a route by its identifier.
## - `subscribe(set, eventId, <Event>, onEvent, …)` subscribes to one Runtime
##   Control event (l.3868), typed as a route's events are, with `onEnd` for a
##   subscription the binding ended (l.1476-1483). The binding's
##   `observe_subscription_end` is registered once, before the first one
##   (`consumert.BindingEvents`); a module uses these subscriptions or its own
##   registration, not both, and one `RouteSet` per binding.
##
## **On the module's own binding** the establishment response has no
## continuations and only ready routes (R l.3019-3020); anything else is a
## Runtime fault and fails MODULE_ERROR before any route is materialized.
## `partial` is returned as it is (R l.3047). Continuations through a
## `connect_remote` binding (R l.3031) are not handled here.
##
## **Inside the binding's subscription-end callback** every operation of this
## module through the same binding is refused NOT_READY (l.1480); a plain
## module defers its reaction to another thread.
##
## Operations through one Runtime Control binding may run concurrently
## (l.1911); the set's bookkeeping is locked, and `close` must not run
## concurrently with the set's other operations.

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, sysrand]
import results
import ../abi/[checks, types]
import ../codegen/consumert
import ./rcclient

export consumert, rcclient

type
  HeldKind = enum
    hkHandle
    hkCall

  Held = object
    next: ptr Held
    kind: HeldKind
    handle: RouteHandle ## `hkHandle`
    call: PreparedCall ## `hkCall`

  RouteSetObj = object
    rc: ptr LogosRuntimeControlBinding
    lock: Lock ## `held`; never held across a binding call
    held: ptr Held
    events: BindingEvents

  RouteSet* = ptr RouteSetObj ## One module instance's routes; `close` it once.

  OpenedRoute* = object ## One route `openRoute` established.
    record*: LogosNSRuntimeControlRouteRecord
      ## As the Runtime returned it, without its one-time `invocation`.
    handle*: Result[RouteHandle, InvocationFailure]
      ## The wrapped handle, held by the set; or why it could not be made.

  OpenedRoutes* = object
    partial*: bool ## a provider of `all-runtime-visible` was omitted (R l.3047)
    routes*: seq[OpenedRoute]

  Cardinality* = LogosNSRuntimeControlProviderRequirementCardinalityKind

# Helpers ---------------------------------------------------------------------------

func toFailure(f: RcFailure): InvocationFailure =
  failure(f.code, f.message)

proc admit(s: RouteSet): Result[void, InvocationFailure] =
  if s.isNil:
    return err(failure(ecInvalidParams, "a null route set"))
  if insideBindingEnd(s.rc):
    return err(
      failure(
        ecNotReady,
        "a Runtime Control operation from the binding's subscription-end callback (INTERFACE l.1480)",
      )
    )
  ok()

var keyCounter: Atomic[int64]

proc freshKey*(): string =
  ## A fresh `request_key` (RUNTIME l.3072): 128 random bits, hex.
  var b: array[16, byte]
  if not urandom(b):
    # [IMPL] Without system randomness: a counter and the time, unique within
    # this process.
    let v = keyCounter.fetchAdd(1) + 1
    let t = getMonoTime().ticks
    for i in 0 ..< 8:
      b[i] = byte((v shr (8 * i)) and 0xff)
      b[8 + i] = byte((t shr (8 * i)) and 0xff)
  const hex = "0123456789abcdef"
  result = "lcn-"
  for x in b:
    result.add hex[int(x shr 4)]
    result.add hex[int(x and 0xf)]

# The set ------------------------------------------------------------------------------

proc newRouteSet*(
    rc: ptr LogosRuntimeControlBinding
): Result[RouteSet, InvocationFailure] =
  ## A set over the instance's binding, checked as INTERFACE §5.2 requires.
  checkBinding(rc).isOkOr:
    return err(toFailure(error))
  let s = cast[RouteSet](allocShared0(sizeof(RouteSetObj)))
  s.rc = rc
  initLock(s.lock)
  s.events = newBindingEvents(rc)
  ok(s)

proc binding*(s: RouteSet): ptr LogosRuntimeControlBinding =
  s.rc

proc hold(s: RouteSet, x: Held) =
  let n = cast[ptr Held](allocShared0(sizeof(Held)))
  n[] = x
  acquire(s.lock)
  n.next = s.held
  s.held = n
  release(s.lock)

proc take(s: RouteSet, h: RouteHandle, c: PreparedCall): ptr Held =
  ## Unlinks the entry that holds `h` (or `c`), if any.
  acquire(s.lock)
  var prev: ptr Held = nil
  var n = s.held
  while n != nil:
    let same =
      case n.kind
      of hkHandle:
        not h.isNil and n.handle == h
      of hkCall:
        not c.isNil and n.call == c
    if same:
      if prev.isNil:
        s.held = n.next
      else:
        prev.next = n.next
      n.next = nil
      break
    prev = n
    n = n.next
  release(s.lock)
  n

proc putBack(s: RouteSet, n: ptr Held) =
  acquire(s.lock)
  n.next = s.held
  s.held = n
  release(s.lock)

proc adopt*(s: RouteSet, h: RouteHandle) =
  ## The set holds `h` from now on; release it with `s.release(h)`.
  if not s.isNil and not h.isNil:
    s.hold(Held(kind: hkHandle, handle: h))

proc adopt*(s: RouteSet, c: PreparedCall) =
  ## The set holds `c` from now on; release it with `s.release(c)`.
  if not s.isNil and not c.isNil:
    s.hold(Held(kind: hkCall, call: c))

proc release*(s: RouteSet, h: RouteHandle): Result[void, InvocationFailure] =
  ## Releases a handle the set holds (`consumert.release`). A refused release
  ## leaves it held.
  let n = s.take(h, PreparedCall())
  let r = h.release()
  if n != nil:
    if r.isErr:
      s.putBack(n)
    else:
      deallocShared(n)
  r

proc release*(s: RouteSet, c: PreparedCall): Result[void, InvocationFailure] =
  ## Releases a prepared call the set holds (`consumert.release`). A refused
  ## release leaves it held.
  let n = s.take(nil, c)
  let r = c.release()
  if n != nil:
    if r.isErr:
      s.putBack(n)
    else:
      deallocShared(n)
  r

proc close*(s: RouteSet, initFailed = false): Result[void, InvocationFailure] =
  ## Releases everything the set still holds: prepared calls first (each waits
  ## for a running completion), then route handles (each waits for its
  ## handlers), then the Runtime Control subscriptions (each waits for its
  ## handlers). In `_MODULE_destroy` (l.1959-1960) and, with `initFailed`,
  ## before `_MODULE_init` returns a failure, when the binding's end
  ## registration is kept (l.1954). Every item is released; the first failure is
  ## returned. `s` is not used again.
  if s.isNil:
    return ok()
  ?s.admit()
  var first = Result[void, InvocationFailure].ok()
  acquire(s.lock)
  var n = s.held
  s.held = nil
  release(s.lock)
  for pass in [hkCall, hkHandle]:
    var m = n
    while m != nil:
      if m.kind == pass:
        let r =
          if pass == hkCall:
            m.call.release()
          else:
            m.handle.release()
        if r.isErr and first.isOk:
          first = r
      m = m.next
  while n != nil:
    let next = n.next
    deallocShared(n)
    n = next
  let r = s.events.close(keepRegistration = initFailed)
  if r.isErr and first.isOk:
    first = r
  deinitLock(s.lock)
  deallocShared(s)
  first

# Opening routes -------------------------------------------------------------------------

proc materialize*(
    s: RouteSet,
    route: string,
    root: ContractRoot,
    schema: openArray[byte],
    onRouteEnd: RouteEndProc = nil,
    user: pointer = nil,
): Result[RouteHandle, InvocationFailure] =
  ## [SPEC INTERFACE §5.2; RUNTIME l.3033-3034] Materializes a ready route as
  ## a handle, wraps it and holds it. `root` is the contract the caller
  ## expects and `schema` its construction input.
  ?s.admit()
  if schema.len == 0:
    return err(failure(ecInvalidParams, "an empty schema"))
  var expected = root
  var raw = LogosRouteHandle()
  let r = s.rc.vtable.materializeRoute(
    s.rc,
    cstring(route),
    addr expected,
    cast[ptr UncheckedArray[uint8]](unsafeAddr schema[0]),
    csize_t(schema.len),
    addr raw,
  )
  readStatus(r).isOkOr:
    let f = error
    return err(InvocationFailure(code: f.code, message: f.message, detail: f.detail))
  let h = ?wrapRoute(raw, onRouteEnd, user)
  s.adopt(h)
  ok(h)

proc openRoute*(
    s: RouteSet,
    root: ContractRoot,
    schema: openArray[byte],
    access = LogosNSRuntimeControlRouteAccess(),
    cardinality = Cardinality.Single,
    provider = Opt.none(LogosNSRuntimeModuleProviderAddress),
    requestKey = "",
    onRouteEnd: RouteEndProc = nil,
    user: pointer = nil,
): Result[OpenedRoutes, InvocationFailure] =
  ## [SPEC RUNTIME §9.3] Establishes routes to the contract `root` and
  ## materializes each one (`materialize`). `requestKey` is fresh when empty.
  ## The establishment's own failure fails the whole; after it, each route has
  ## its own outcome in `routes`.
  ?s.admit()
  let req = LogosNSRuntimeControlEstablishRouteRequest(
    request_key:
      if requestKey.len == 0:
        freshKey()
      else:
        requestKey,
    contract: SchemaCommitment(schema_root: @root),
    cardinality: LogosNSRuntimeControlProviderRequirementCardinality(kind: cardinality),
    provider: provider,
    access: access,
  )
  let resp = call(
    s.rc, "establish_route", req, LogosNSRuntimeControlEstablishRouteResponse
  ).valueOr:
    return err(toFailure(error))
  # [SPEC RUNTIME l.3019-3020] The module-facing response.
  if resp.continuations.len > 0:
    return err(
      moduleError(
        "establish_route returned continuations to a module's own binding (RUNTIME l.3020)"
      )
    )
  for rec in resp.routes:
    if rec.state.kind != LogosNSRuntimeControlRouteStateKind.Ready:
      return err(
        moduleError(
          "establish_route returned route " & rec.route & " in state " & $rec.state.kind &
            " (RUNTIME l.3020)"
        )
      )
  var opened = OpenedRoutes(partial: resp.partial)
  for rec in resp.routes:
    var o = OpenedRoute(
      record: rec, handle: s.materialize(rec.route, root, schema, onRouteEnd, user)
    )
    o.record.invocation = Opt.none(LogosNSRuntimeControlInvocationDescriptor)
    opened.routes.add o
  ok(opened)

proc renewRoute*(
    s: RouteSet, route: string, requestKey = ""
): Result[LogosNSRuntimeControlRouteRecord, InvocationFailure] =
  ## [SPEC RUNTIME §9.3] Renews a route; `requestKey` is fresh when empty. The
  ## record's `invocation` is what a later `materialize` uses.
  ?s.admit()
  let req = LogosNSRuntimeControlRenewRouteRequest(
    request_key:
      if requestKey.len == 0:
        freshKey()
      else:
        requestKey,
    route: route,
  )
  let resp = call(s.rc, "renew_route", req, LogosNSRuntimeControlRenewRouteResponse).valueOr:
    return err(toFailure(error))
  ok(resp.route)

proc closeRoute*(
    s: RouteSet, route: string, reason = Opt.none(string)
): Result[LogosNSRuntimeControlCloseRouteResponse, InvocationFailure] =
  ## [SPEC RUNTIME §9.3] Closes a route. Its handle, if the set holds one,
  ## reports the end (`onRouteEnd`, NOT_READY, l.1455) and is still released
  ## through the set.
  ?s.admit()
  let req = LogosNSRuntimeControlCloseRouteRequest(route: route, reason: reason)
  call(s.rc, "close_route", req, LogosNSRuntimeControlCloseRouteResponse).mapErr(
    toFailure
  )

# Runtime Control subscriptions ------------------------------------------------------------

proc subscribe*[E](
    s: RouteSet,
    event: string,
    T: typedesc[E],
    onEvent: EventProc[E],
    onEnd: SubscriptionEndProc = nil,
    onInvalid: InvalidEventProc = nil,
    user: pointer = nil,
): Result[Subscription, InvocationFailure] =
  ## A Runtime Control event (INTERFACE l.3868) by its schema event identifier,
  ## such as `logos.runtime_control.module_state_changed_event`, decoded as `E`.
  ## `unsubscribe` it, or `close` the set.
  ?s.admit()
  subscribeTyped(s.events, event, T, onEvent, onEnd, onInvalid, user)
