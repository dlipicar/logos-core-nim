## lcn_call's routes (Tier 5 step N-2; DECISIONS G348): established, kept and
## reused across commands, renewed, and closed when idle. docs/DAEMON.md §7a.
##
## - **Key.** A route is kept per (target, provider, selected contract, access
##   kind, the one method or event root). Its access names exactly that member
##   (`{methods: [root]}` or `{subscribe_events: [root]}`): the Capability
##   Authority never narrows, so a wider request would be refused under a
##   narrower grant, and a route that cannot carry a marked method is no path
##   for its payloads (IF l.388).
## - **Establish.** `establish_route` with one provider, cardinality
##   `single`, a request key `lcall-` and 32 hex digits; on the local binding
##   one ready record and no continuation. `materialize_route` takes the
##   surface projected to the selected contract (IF l.3874).
## - **Handles.** Each handle sits in shared memory with its own count of
##   operations in flight. Every operation on a route's handles holds that
##   route's lock (IF l.1980). Lock order: a route's lock, then the table's;
##   no thread waits for a route's lock while it holds the table's.
## - **Renewal.** When less than a tenth of the validity or 5 s remain,
##   `renew_route` and a new handle: a renewal does not extend an existing
##   session (R l.3477-3478), so new operations go to the new handle and the
##   old one is released once its operations have ended.
## - **End.** `observe_end` marks a handle ended; the next command establishes
##   a new route. A call that failed on an ended handle is retried once.
## - **Idle.** A route unused for `route_idle_ms` is closed (`close_route`) and
##   its handles released, by `reap`, which the server calls once a second.
## - **Destroy.** `closeTable`, after every worker has ended: every handle
##   released, every live route closed.

{.push raises: [], gcsafe.}

import std/[locks, monotimes, sysrand, times]
import results
import logos_sdk/abi/[checks, types]
import logos_sdk/base/hex
import logos_sdk/hash/hashinput
import logos_sdk/iface/outcome
import logos_sdk/kit/rc_types
import ./rpc

export results

const
  MaxRoutes* = 128 ## [IMPL] routes kept at once
  MaxRetired = 4 ## renewed handles still in use, per route
  RenewMarginMs = 5_000
  RequestKeyPrefix* = "lcall-"

type
  SharedBuf = object
    data: ptr UncheckedArray[byte]
    len: int

  Box = object ## One materialized handle.
    handle: LogosRouteHandle
    inflight: int
    retired, ended: bool
    tag: ptr EndTag

  EndTag = object ## `observe_end`'s user data.
    table: ptr TableObj
    box: ptr Box

  Slot = object
    used: bool
    key: Digest
    routeId, schema: SharedBuf
    contract: Digest
    current: ptr Box
    retired: array[MaxRetired, ptr Box]
    renewing: bool
    establishedMs, expiresMs: int64 ## wall-clock ms; expiresMs 0: no expiry
    lastUsed: MonoTime

  TableObj = object
    lock: Lock
    establishing: Lock ## one establishment at a time
    handleLocks: array[MaxRoutes, Lock] ## per slot, IF l.1980
    rc: ptr LogosRuntimeControlBinding
    idleMs: int
    slots: array[MaxRoutes, Slot]

  RouteTable* = ptr TableObj

  RouteSpec* = object ## What a command needs a route for.
    key*: Digest
    contract*: Digest ## the selected contract's root
    provider*: LogosNSRuntimeModuleProviderAddress
    access*: LogosNSRuntimeControlRouteAccess
    schema*: seq[byte] ## the projected `logos.schema_response`

  Lease* = object ## One command's use of a route's current handle.
    slot: int
    box: ptr Box
    route*: ptr LogosRouteHandle
    lock*: ptr Lock
    routeId*: string

  Detached = object ## A slot taken out of the table, to finish outside its lock.
    slot: int
    routeId: SharedBuf
    schema: SharedBuf
    boxes: seq[ptr Box]
    close: bool

proc share(b: openArray[byte]): SharedBuf =
  if b.len > 0:
    result.data = cast[ptr UncheckedArray[byte]](allocShared(b.len))
    copyMem(result.data, unsafeAddr b[0], b.len)
    result.len = b.len

proc share(s: string): SharedBuf =
  share(s.toOpenArrayByte(0, s.high))

proc free(b: var SharedBuf) =
  if b.data != nil:
    deallocShared(b.data)
  b = SharedBuf()

proc textOf(b: SharedBuf): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc bytesOf(b: SharedBuf): seq[byte] =
  result = newSeq[byte](b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc wallMs(): int64 =
  let t = getTime()
  t.toUnix * 1000 + int64(t.nanosecond div 1_000_000)

proc requestKey*(): Result[string, Failure] =
  ## [G348] `lcall-` and 32 hex digits from the OS's randomness.
  var b: array[16, byte]
  if not urandom(b):
    return err(failure(ecModule, "no randomness for a request key"))
  ok(RequestKeyPrefix & toHex(b))

# The table ----------------------------------------------------------------------------

proc newRouteTable*(rc: ptr LogosRuntimeControlBinding, idleMs: int): RouteTable =
  result = cast[RouteTable](allocShared0(sizeof(TableObj)))
  initLock(result.lock)
  initLock(result.establishing)
  for i in 0 ..< MaxRoutes:
    initLock(result.handleLocks[i])
  result.rc = rc
  result.idleMs = idleMs

proc onEnd(reason: CErrorCode, userData: pointer) {.cdecl, gcsafe, raises: [].} =
  ## [SPEC INTERFACE §2.8] The route ended: the handle takes no new command.
  let tag = cast[ptr EndTag](userData)
  withLock tag.table.lock:
    tag.box.ended = true

proc freeBox(b: ptr Box) =
  if b.tag != nil:
    deallocShared(b.tag)
  deallocShared(b)

proc releaseBox(t: RouteTable, slot: int, b: ptr Box) =
  ## [SPEC INTERFACE l.3896] No operation is in flight on `b`; every response
  ## buffer was released by its completion.
  withLock t.handleLocks[slot]:
    b.handle.vtable.release(addr b.handle)
  freeBox(b)

proc materialize(
    t: RouteTable, routeId: string, contract: Digest, schema: openArray[byte]
): Result[ptr Box, Failure] =
  ## [SPEC INTERFACE l.3870-3877] A handle for `routeId`, with its end handler.
  var root: ContractRoot
  for i in 0 ..< root.len:
    root[i] = contract[i]
  let box = cast[ptr Box](allocShared0(sizeof(Box)))
  let p =
    if schema.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr schema[0])
  let r = t.rc.vtable.materializeRoute(
    t.rc, cstring(routeId), addr root, p, csize_t(schema.len), addr box.handle
  )
  let shaped = checkOutcome(r, handleShape(box.handle.vtable, box.handle.state))
  if shaped.isErr:
    if int64(r.code) == 0 and box.handle.vtable != nil and
        checkRoute(addr box.handle).isOk:
      box.handle.vtable.release(addr box.handle)
    freeBox(box)
    return err(failureOf(shaped.error))
  let checked = checkRoute(addr box.handle)
  if checked.isErr:
    freeBox(box)
    return err(failureOf(checked.error))
  box.tag = cast[ptr EndTag](allocShared0(sizeof(EndTag)))
  box.tag.table = t
  box.tag.box = box
  let o = box.handle.vtable.observeEnd(addr box.handle, onEnd, box.tag)
  if int64(o.code) != 0:
    # Already ended, or no end to observe: the handle serves this command only.
    withLock t.lock:
      box.ended = true
  ok(box)

func failureOfRecord(r: LogosNSRuntimeControlRouteRecord): Failure =
  let code =
    if r.failure.isSome:
      r.failure.get.code
    else:
      "route-" & $r.state.kind
  let msg =
    if r.failure.isSome and r.failure.get.message.isSome:
      r.failure.get.message.get
    else:
      ""
  failure(ecNotReady, code & (if msg.len > 0: ": " & msg else: ""))

proc expiresOf(r: LogosNSRuntimeControlRouteRecord): int64 =
  if r.expires_at.isSome:
    int64(r.expires_at.get)
  else:
    0

proc establish(
    t: RouteTable, spec: RouteSpec, cancelFd: cint
): Result[(string, int64, ptr Box), Failure] =
  ## [SPEC RUNTIME §9.3] One route to the one provider, then its handle.
  let key = ?requestKey()
  let req = LogosNSRuntimeControlEstablishRouteRequest(
    request_key: key,
    contract: SchemaCommitment(schema_root: @(spec.contract)),
    cardinality: LogosNSRuntimeControlProviderRequirementCardinality(
      kind: LogosNSRuntimeControlProviderRequirementCardinalityKind.Single
    ),
    provider: Opt.some(spec.provider),
    access: spec.access,
  )
  let resp = ?rcCall(
    t.rc, "establish_route", req, LogosNSRuntimeControlEstablishRouteResponse, cancelFd
  )
  if resp.continuations.len > 0:
    return err(
      failure(
        ecNotReady,
        "establish_route answered with a remote continuation; remote providers come " &
          "with Tier 5 step 5-7a",
      )
    )
  if resp.routes.len != 1:
    return err(
      failure(
        ecModule, "establish_route answered " & $resp.routes.len & " routes, not 1"
      )
    )
  let rec = resp.routes[0]
  if rec.state.kind != LogosNSRuntimeControlRouteStateKind.Ready:
    return err(failureOfRecord(rec))
  let box = ?t.materialize(rec.route, spec.contract, spec.schema)
  ok((rec.route, expiresOf(rec), box))

proc closeRoute(t: RouteTable, routeId: string) =
  let req =
    LogosNSRuntimeControlCloseRouteRequest(route: routeId, reason: Opt.some("idle"))
  discard rcCall(t.rc, "close_route", req, LogosNSRuntimeControlCloseRouteResponse)

proc detach(t: RouteTable, i: int, close: bool): Detached =
  ## Under the table's lock: the slot's route and handles, out of the table.
  let s = addr t.slots[i]
  result = Detached(slot: i, routeId: s.routeId, schema: s.schema, close: close)
  if s.current != nil:
    result.boxes.add(s.current)
  for r in s.retired.mitems:
    if r != nil:
      result.boxes.add(r)
      r = nil
  s[] = Slot()

proc finish(t: RouteTable, d: var Detached) =
  ## Outside the table's lock: release the handles, then close the route.
  for b in d.boxes:
    t.releaseBox(d.slot, b)
  if d.close:
    t.closeRoute(textOf(d.routeId))
  free(d.routeId)
  free(d.schema)

func busy(s: Slot): bool =
  if s.renewing:
    return true
  if s.current != nil and s.current.inflight > 0:
    return true
  for r in s.retired:
    if r != nil and r.inflight > 0:
      return true
  false

proc find(t: RouteTable, key: Digest): int =
  ## Under the table's lock: the live slot for `key`, or -1.
  for i in 0 ..< MaxRoutes:
    let s = addr t.slots[i]
    if s.used and s.key == key and s.current != nil and not s.current.ended:
      return i
  -1

proc freeSlot(t: RouteTable, victim: var Opt[Detached]): int =
  ## Under the table's lock: an unused slot, or the least recently used idle
  ## one, detached for closing; -1 when every slot is in use.
  for i in 0 ..< MaxRoutes:
    if not t.slots[i].used:
      return i
  var best = -1
  for i in 0 ..< MaxRoutes:
    if not t.slots[i].busy and (
      best < 0 or t.slots[i].lastUsed < t.slots[best].lastUsed
    ):
      best = i
  if best >= 0:
    let ended = t.slots[best].current == nil or t.slots[best].current.ended
    victim = Opt.some(t.detach(best, not ended))
  best

proc lease(t: RouteTable, i: int): Lease =
  ## Under the table's lock.
  let s = addr t.slots[i]
  inc s.current.inflight
  s.lastUsed = getMonoTime()
  Lease(
    slot: i,
    box: s.current,
    route: addr s.current.handle,
    lock: addr t.handleLocks[i],
    routeId: textOf(s.routeId),
  )

func needsRenewal(s: Slot, now: int64): bool =
  if s.expiresMs <= 0:
    return false
  let validity = max(s.expiresMs - s.establishedMs, 0)
  s.expiresMs - now < max(validity div 10, RenewMarginMs)

proc renew(t: RouteTable, i: int) =
  ## [SPEC RUNTIME l.3477-3478] Called with the slot marked `renewing`: a
  ## renewal and a new handle; on any failure the current handle stays in use
  ## until it ends.
  var routeId, schema: string
  var contract: Digest
  var schemaBytes: seq[byte]
  withLock t.lock:
    routeId = textOf(t.slots[i].routeId)
    schemaBytes = bytesOf(t.slots[i].schema)
    contract = t.slots[i].contract
  discard schema
  var fresh: ptr Box = nil
  var expires = 0'i64
  block attempt:
    let key = requestKey().valueOr:
      break attempt
    let r = rcCall(
      t.rc,
      "renew_route",
      LogosNSRuntimeControlRenewRouteRequest(request_key: key, route: routeId),
      LogosNSRuntimeControlRenewRouteResponse,
    )
    if r.isErr or r.get.route.state.kind != LogosNSRuntimeControlRouteStateKind.Ready:
      break attempt
    expires = expiresOf(r.get.route)
    let b = t.materialize(routeId, contract, schemaBytes)
    if b.isErr:
      break attempt
    fresh = b.get
  var release: ptr Box = nil
  withLock t.lock:
    let s = addr t.slots[i]
    s.renewing = false
    if fresh != nil:
      var placed = false
      for r in s.retired.mitems:
        if r == nil:
          r = s.current
          placed = true
          break
      if placed:
        s.current.retired = true
        if s.current.inflight == 0:
          release = s.current
          for r in s.retired.mitems:
            if r == release:
              r = nil
        s.current = fresh
        s.establishedMs = wallMs()
        s.expiresMs = expires
      else:
        release = fresh # no room for another retired handle: keep the current one
  if release != nil:
    t.releaseBox(i, release)

proc acquire*(
    t: RouteTable, spec: RouteSpec, cancelFd: cint = -1
): Result[Lease, Failure] =
  ## [G348] A lease on the route for `spec.key`, established if there is none;
  ## readable `cancelFd` cancels an establishment.
  var renewSlot = -1
  withLock t.lock:
    let i = t.find(spec.key)
    if i >= 0:
      let s = addr t.slots[i]
      if not s.renewing and s[].needsRenewal(wallMs()):
        s.renewing = true
        renewSlot = i
  if renewSlot >= 0:
    t.renew(renewSlot)
  withLock t.lock:
    let i = t.find(spec.key)
    if i >= 0:
      return ok(t.lease(i))
  # None: one establishment at a time, and a second look once it is ours.
  var victim = Opt.none(Detached)
  var result0: Result[Lease, Failure]
  withLock t.establishing:
    var again = -1
    withLock t.lock:
      again = t.find(spec.key)
      if again >= 0:
        result0 = ok(t.lease(again))
    if again < 0:
      let made = t.establish(spec, cancelFd)
      if made.isErr:
        result0 = err(made.error)
      else:
        let (routeId, expires, box) = made.get
        var slot = -1
        var orphan: ptr Box = nil
        withLock t.lock:
          slot = t.freeSlot(victim)
          if slot < 0:
            orphan = box
          else:
            t.slots[slot] = Slot(
              used: true,
              key: spec.key,
              routeId: share(routeId),
              schema: share(spec.schema),
              contract: spec.contract,
              current: box,
              establishedMs: wallMs(),
              expiresMs: expires,
              lastUsed: getMonoTime(),
            )
            result0 = ok(t.lease(slot))
        if orphan != nil:
          withLock t.handleLocks[0]:
            orphan.handle.vtable.release(addr orphan.handle)
          freeBox(orphan)
          t.closeRoute(routeId)
          result0 =
            err(failure(ecNotReady, "lcn_call holds " & $MaxRoutes & " routes in use"))
  if victim.isSome:
    var d = victim.get
    t.finish(d)
  result0

proc ended*(t: RouteTable, l: Lease): bool =
  ## Whether the leased handle's route has ended.
  withLock t.lock:
    result = l.box.ended

proc done*(t: RouteTable, l: Lease) =
  ## The command no longer uses the handle; a retired one with nothing in
  ## flight is released.
  var release: ptr Box = nil
  withLock t.lock:
    dec l.box.inflight
    let s = addr t.slots[l.slot]
    s.lastUsed = getMonoTime()
    if l.box.retired and l.box.inflight == 0:
      release = l.box
      for r in s.retired.mitems:
        if r == release:
          r = nil
  if release != nil:
    t.releaseBox(l.slot, release)

proc reap*(t: RouteTable) =
  ## [G348] Closes routes idle for `route_idle_ms`, drops ended ones, and
  ## releases retired handles with nothing in flight.
  var detached: seq[Detached] = @[]
  var retired: seq[(int, ptr Box)] = @[]
  let now = getMonoTime()
  withLock t.lock:
    for i in 0 ..< MaxRoutes:
      let s = addr t.slots[i]
      if not s.used:
        continue
      for r in s.retired.mitems:
        if r != nil and r.inflight == 0:
          retired.add((i, r))
          r = nil
      if s[].busy:
        continue
      if s.current == nil or s.current.ended:
        detached.add(t.detach(i, false))
      elif inMilliseconds(now - s.lastUsed) >= t.idleMs:
        detached.add(t.detach(i, true))
  for (i, b) in retired:
    t.releaseBox(i, b)
  for d in detached.mitems:
    t.finish(d)

proc closeTable*(t: RouteTable) =
  ## At destroy, after every worker has ended: every handle released, every
  ## live route closed, the table freed.
  var detached: seq[Detached] = @[]
  withLock t.lock:
    for i in 0 ..< MaxRoutes:
      if t.slots[i].used:
        let ended = t.slots[i].current == nil or t.slots[i].current.ended
        detached.add(t.detach(i, not ended))
  for d in detached.mitems:
    t.finish(d)
  for i in 0 ..< MaxRoutes:
    deinitLock(t.handleLocks[i])
  deinitLock(t.establishing)
  deinitLock(t.lock)
  deallocShared(t)

proc routeCount*(t: RouteTable): int =
  ## Routes kept, for tests and the log.
  withLock t.lock:
    for s in t.slots:
      if s.used:
        inc result

{.pop.}
