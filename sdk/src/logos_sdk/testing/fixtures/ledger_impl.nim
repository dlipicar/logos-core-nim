## A thread-confined module written with the lcn-gen kit for `ledger_module`
## (`ledger_module.cddl`; DECISIONS G335-G337): what a module author writes
## with `lcn-gen kit --confined`. `sdk/tests/test_kit_confined.nim` links it in
## process; core's mixed-manager suite builds it as a library with the other
## memory manager. Its instance keeps GC'd state (a table, a list, an
## `Invocation`) that only its module thread touches, and its `initModule` is
## `async`.
##
## `post` adds `amount` to the entry `key`, keeps the key and publishes
## `ledger.posted_event` (queued). `probe` (plain) by channel: 1 reads the
## caller; 2 publishes in the invocation's scope; 3 fails with a message; 4
## reads whether the invocation is cancelled; 5 publishes `value` events
## through `publish` and reads how many the kit refused; 6 reads the caller
## through the `Invocation` an earlier `wait` 4 kept; 7 has `value` foreign C
## threads post 10 callbacks each (`foreign_lib.c`); 8 calls the test's
## `probeHook` with `value`, then reads the caller again; 9 reads the publish
## callback's refusals. `wait` (async) by channel: 1 sleeps `millis`, then
## reads the caller; 2 publishes in its invocation's scope without awaiting;
## 3 awaits `publishAsync`; 4 keeps its `Invocation`; 5 fails; 6 reads the
## caller through the plain API (NOT_READY in an async task); 7 awaits a
## publication in its invocation's scope; 8 reads whether its invocation is
## cancelled; 9 sleeps `millis` and answers CANCELLED when its future is
## cancelled meanwhile (a submitted invocation's cancellation, G338); 10 calls
## `meter.read` of channel `value` with `invokeAsync` through the handle `probe`
## 10 wrapped, with a deadline of `millis` when nonzero; 11 sleeps `millis`
## and ignores a cancellation (`noCancel`). `seal` (marked)
## returns its secret reversed and masked. Every response names its handler's
## thread. The kit also exports `_MODULE_async_api` (`--async-api`).
##
## As a consumer (DECISIONS G339), `probe` by channel: 10 wraps the route
## handle the test put in `routeToWrap` with the kit's dispatcher and
## subscribes to `meter.changed_event` through the generated meter helpers; 11
## unsubscribes; 12 releases the handle; 13 prepares and submits `meter.read`
## of channel `value`; 14 reports what its handlers recorded; 15 releases the
## prepared call; 16 sets the delivery bound to `value`; 17 prepares, submits
## and releases a call in one handler. Its handlers record on the instance,
## and count any call off its module thread. A changed event of value 98
## tries an operation on its own handle; 99 unsubscribes its own subscription.
##
## Placed by a Runtime (core's mixed-manager suite), `probe` by channel: 18
## opens a route to the meter through a `RouteSet` over its Runtime Control
## binding (`<state_dir>/route.cmd`: the meter's contract root and
## construction input in hex, one per line) and subscribes as 10 does; 19
## holds the module thread until `<state_dir>/open` exists, after writing
## `<state_dir>/held`; 20 closes that route through the set and reports the
## route end seen meanwhile; 21 publishes `ledger.posted_event` (key `timer`)
## from a chronos timer `value` ms later; 22 reads `posts`, `postThreads` and
## how many of this instance's `post` publications the kit refused (its queue
## full); 23 reads how many `wait` 9 handlers of the library saw cancelled and
## how many sleep now (`<cancelled> <sleeping>`).

{.used.} # imported by the tests for the C symbols it exports
import std/[atomics, os, strutils, tables]
import ../generated/[ledger_module_kit, meter_module_calls]
import ../../kit/routes

{.compile: "foreign_lib.c".}

proc foreignPost(
  poster: pointer, fn: PostFn, threads, count: cint
): cint {.importc: "lcn_foreign_post", cdecl, gcsafe, raises: [].}

type
  FreedMark = object
    ## Counts its instance in `freed` when the instance's memory goes; a moved-from
    ## mark is not live.
    live: bool

  Ledger* = ref object
    mark: FreedMark
    services*: ModuleServices
    entries: Table[string, uint64]
    keys: seq[string]
    kept: Invocation
    # As a consumer (G339): module thread only, GC'd values included.
    route: RouteHandle
    sub: Subscription
    call: PreparedCall
    seen: seq[uint64]
    offThread: int
    endNote, routeEndNote, doneNote, ruleNote: string
    stateDir: string
    refused: int ## `post` publications the kit refused
    set: RouteSet ## from `probe` 18
    routeId: string

var
  destroyed*: Atomic[int] ## instances `destroyModule` has seen
  freed*: Atomic[int] ## instances whose memory was freed
  posts*: Atomic[int] ## callbacks foreign threads posted that ran
  cancelledWaits*: Atomic[int] ## `wait` 9 handlers whose future was cancelled
  sleepingWaits*: Atomic[int] ## `wait` 9 handlers asleep now
  postThreads*: Atomic[int] ## how many of them did not run on a module thread
  probeHook*: proc(m: Ledger, value: uint64): string {.nimcall, gcsafe, raises: [].}
    ## what `probe` 8 calls; the test sets it
  routeToWrap*: LogosRouteHandle ## what `probe` 10 wraps; the test sets it

proc `=destroy`(m: FreedMark) =
  if m.live:
    freed += 1

proc `=copy`(a: var FreedMark, b: FreedMark) {.error.}

proc threadNumber(): uint64 =
  uint64(getThreadId())

proc initModule(
    _: type Ledger, init: ModuleInit
): Future[Result[Ledger, InvocationFailure]] {.async: (raises: []).} =
  if init.stateDir == Opt.some("/refuse"): # refuse to start
    return Result[Ledger, InvocationFailure].err(
      failure(ecModule, "the state directory says no")
    )
  try:
    await sleepAsync(1.milliseconds)
  except CancelledError:
    discard
  Result[Ledger, InvocationFailure].ok(
    Ledger(
      mark: FreedMark(live: true),
      services: init.services,
      stateDir: init.stateDir.get(""),
    )
  )

proc destroyModule(m: Ledger) =
  m.kept = nil
  if not m.call.isNil:
    discard m.call.release()
  if not m.set.isNil:
    discard m.set.close() # the route it holds too
  elif not m.route.isNil:
    discard m.route.release()
  destroyed += 1

proc callerNote(r: Result[Caller, InvocationFailure]): string =
  if r.isOk:
    r.unsafeGet.moduleInstance.get("")
  else:
    $r.unsafeError.code

proc statusNote(r: Result[void, InvocationFailure]): string =
  if r.isOk:
    "ok"
  else:
    $r.unsafeError.code

proc ledgerOf(user: pointer): Ledger =
  let m = cast[Ledger](user)
  if not m.services.onItsModuleThread():
    inc m.offThread
  m

proc onRead(
    outcome: Result[MeterReadResponse, InvocationFailure], user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let m = ledgerOf(user)
  m.doneNote =
    if outcome.isOk:
      "ok:" & outcome.unsafeGet.label
    else:
      $outcome.unsafeError.code

proc onChanged(e: MeterChangedEvent, user: pointer) {.nimcall, gcsafe, raises: [].} =
  let m = ledgerOf(user)
  case e.value
  of 98: # the handler rule (INTERFACE l.1939)
    let r = m.route.prepareInvoke(MeterReadRequest(channel: 1), onRead, user)
    m.ruleNote =
      if r.isOk:
        discard r.unsafeGet.release()
        "ok"
      else:
        $r.unsafeError.code
  of 99:
    m.ruleNote = statusNote(m.sub.unsubscribe())
  else:
    m.seen.add(e.value)

proc onSubEnd(
    sub: Subscription, reason: ErrorCode, user: pointer
) {.nimcall, gcsafe, raises: [].} =
  ledgerOf(user).endNote = $reason

proc onRouteEnded(code: ErrorCode, user: pointer) {.nimcall, gcsafe, raises: [].} =
  ledgerOf(user).routeEndNote = $code

proc seenCount*(m: Ledger): int =
  ## For a test hook on the module thread.
  m.seen.len

proc unsubscribeChanged*(m: Ledger): string =
  ## For a test hook on the module thread.
  statusNote(m.sub.unsubscribe())

proc unhex(s: string): seq[byte] =
  try:
    let raw = parseHexStr(s.strip)
    @(raw.toOpenArrayByte(0, raw.high))
  except ValueError:
    @[]

proc openMeter(m: Ledger): string =
  ## `probe` 18: a route to the meter through the instance's Runtime Control
  ## binding, with the kit's dispatcher (`newRouteSet(services)`).
  let words =
    try:
      readFile(m.stateDir / "route.cmd").splitLines()
    except IOError:
      return "no route.cmd"
  if words.len < 2:
    return "route.cmd: a root and a schema"
  let rootBytes = unhex(words[0])
  let schema = unhex(words[1])
  if rootBytes.len != 32 or schema.len == 0:
    return "route.cmd: bad hex"
  var root: ContractRoot
  copyMem(addr root[0], unsafeAddr rootBytes[0], 32)
  if m.set.isNil:
    let s = newRouteSet(m.services)
    if s.isErr:
      return "set " & $s.unsafeError.code
    m.set = s.unsafeGet
  let user = cast[pointer](m)
  let opened = m.set.openRoute(root, schema, onRouteEnd = onRouteEnded, user = user)
  if opened.isErr:
    return "open " & $opened.unsafeError.code
  if opened.unsafeGet.routes.len != 1:
    return "routes " & $opened.unsafeGet.routes.len
  let o = opened.unsafeGet.routes[0]
  if o.handle.isErr:
    return "materialize " & $o.handle.unsafeError.code
  m.route = o.handle.unsafeGet
  m.routeId = o.record.route
  let sub = m.route.subscribe(MeterChangedEvent, onChanged, onSubEnd, nil, user)
  if sub.isErr:
    return "subscribe " & $sub.unsafeError.code
  m.sub = sub.unsafeGet
  "subscribed"

proc holdUntilOpen(m: Ledger): string =
  ## `probe` 19: holds the module thread, bounded.
  try:
    writeFile(m.stateDir / "held", "")
  except IOError:
    return "no held"
  for _ in 0 ..< 300_000:
    if fileExists(m.stateDir / "open"):
      return "opened"
    sleep(1)
  "timed out"

proc publishLater(m: Ledger, millis: uint64) {.async: (raises: []).} =
  try:
    await sleepAsync(int(millis).milliseconds)
  except CancelledError:
    return
  discard m.services.publish(LedgerPostedEvent(key: "timer", total: millis))

proc onPosted(payload: pointer) {.cdecl, gcsafe, raises: [].} =
  if not onConfinedThread():
    postThreads += 1
  posts += 1

proc `post`(
    m: Ledger, request: LedgerPostRequest
): Result[LedgerPostResponse, InvocationFailure] =
  let total = m.entries.getOrDefault(request.key) + request.amount
  m.entries[request.key] = total
  m.keys.add(request.key)
  if m.services.publish(LedgerPostedEvent(key: request.key, total: total)).isErr:
    inc m.refused
  ok(LedgerPostResponse(total: total, thread: threadNumber()))

proc `probe`(
    m: Ledger, request: LedgerProbeRequest
): Result[LedgerProbeResponse, InvocationFailure] =
  var note = ""
  case request.channel
  of 1:
    note = callerNote(m.services.caller())
  of 2:
    note = statusNote(
      m.services.publishScoped(LedgerPostedEvent(key: "scoped", total: request.value))
    )
  of 3:
    return err(failure(ecModule, "probe 3 fails"))
  of 4:
    note = if m.services.isCancelled(): "cancelled" else: "live"
  of 5:
    var refused = 0
    for i in 0 ..< int(request.value):
      if m.services.publish(LedgerPostedEvent(key: "flood", total: uint64(i))).isErr:
        inc refused
    note = $refused
  of 6:
    note =
      if m.kept.isNil:
        "none"
      else:
        callerNote(m.kept.caller())
  of 7:
    let poster = cast[pointer](m.services.poster)
    if foreignPost(poster, onPosted, cint(request.value), 10) != 0:
      return err(moduleError("the foreign threads did not start"))
    note = "posted"
  of 8:
    {.cast(gcsafe).}:
      let hook = probeHook
    note =
      (if hook.isNil: "no hook" else: hook(m, request.value)) & "|" &
      callerNote(m.services.caller())
  of 9:
    let last = m.services.lastPublishRefusal()
    note = $m.services.publishRefusals()
    if last.isSome:
      note.add(" " & $last.get.rc & " " & last.get.event)
  of 10:
    let user = cast[pointer](m)
    {.cast(gcsafe).}:
      let raw = routeToWrap
    let h = wrapRoute(raw, onRouteEnded, user, m.services.dispatcher)
    if h.isErr:
      note = $h.unsafeError.code
    else:
      m.route = h.unsafeGet
      let sub = m.route.subscribe(MeterChangedEvent, onChanged, onSubEnd, nil, user)
      note =
        if sub.isOk:
          m.sub = sub.unsafeGet
          "subscribed"
        else:
          $sub.unsafeError.code
  of 11:
    note = statusNote(m.sub.unsubscribe())
  of 12:
    note = statusNote(m.route.release())
    m.route = nil
  of 13:
    let c = m.route.prepareInvoke(
      MeterReadRequest(channel: uint32(request.value)), onRead, cast[pointer](m)
    )
    if c.isErr:
      note = $c.unsafeError.code
    else:
      m.call = c.unsafeGet
      m.call.submit()
      note = "submitted"
  of 14:
    var values: seq[string]
    for v in m.seen:
      values.add($v)
    note =
      "seen=" & values.join(",") & " end=" & m.endNote & " route=" & m.routeEndNote &
      " done=" & m.doneNote & " rule=" & m.ruleNote & " off=" & $m.offThread
  of 15:
    note = statusNote(m.call.release())
    m.call = PreparedCall()
  of 16:
    m.services.setDeliveryBound(int(request.value))
    note = "bound"
  of 17:
    let c = m.route.prepareInvoke(
      MeterReadRequest(channel: uint32(request.value)), onRead, cast[pointer](m)
    )
    if c.isErr:
      note = $c.unsafeError.code
    else:
      c.unsafeGet.submit()
      let during = if m.doneNote.len == 0: "none" else: m.doneNote
      note = during & " " & statusNote(c.unsafeGet.release())
  of 18:
    note = m.openMeter()
  of 19:
    note = m.holdUntilOpen()
  of 20:
    let r = m.set.closeRoute(m.routeId)
    note = (if r.isOk: "ok" else: $r.unsafeError.code) & " route=" & m.routeEndNote
  of 21:
    asyncSpawn m.publishLater(request.value)
    note = "later"
  of 22:
    note = $posts.load & " " & $postThreads.load & " " & $m.refused
  of 23:
    note = $cancelledWaits.load & " " & $sleepingWaits.load
  else:
    discard
  ok(LedgerProbeResponse(value: request.value, thread: threadNumber(), note: note))

proc `wait`(
    m: Ledger, request: LedgerWaitRequest, inv: Invocation
): Future[Result[LedgerWaitResponse, InvocationFailure]] {.async: (raises: []).} =
  var note = ""
  case request.channel
  of 1:
    try:
      await sleepAsync(int(request.millis).milliseconds)
    except CancelledError:
      discard
    note = callerNote(inv.caller())
  of 2:
    discard inv.publishScoped(LedgerPostedEvent(key: "unawaited", total: request.value))
    note = "sent"
  of 3:
    note = statusNote(
      await m.services.publishAsync(
        LedgerPostedEvent(key: "async", total: request.value)
      )
    )
  of 4:
    m.kept = inv
    note = "kept"
  of 5:
    return Result[LedgerWaitResponse, InvocationFailure].err(
      failure(ecModule, "wait 5 fails")
    )
  of 6:
    note = callerNote(m.services.caller())
  of 7:
    note = statusNote(
      await inv.publishScoped(
        LedgerPostedEvent(key: "scoped-async", total: request.value)
      )
    )
  of 8:
    note = if inv.isCancelled(): "cancelled" else: "live"
  of 9:
    sleepingWaits += 1
    try:
      await sleepAsync(int(request.millis).milliseconds)
      sleepingWaits -= 1
    except CancelledError:
      sleepingWaits -= 1
      cancelledWaits += 1
      return Result[LedgerWaitResponse, InvocationFailure].err(
        failure(ecCancelled, "wait 9 was cancelled")
      )
    note = "slept"
  of 10:
    if m.route.isNil:
      note = "no route"
    else:
      let r = await m.route.invokeAsync(
        MeterReadRequest(channel: uint32(request.value)), uint64(request.millis)
      )
      note = (if r.isOk: "ok:" & r.unsafeGet.label else: $r.unsafeError.code)
  of 11:
    await noCancel(sleepAsync(int(request.millis).milliseconds))
    note = "slept"
  else:
    discard
  Result[LedgerWaitResponse, InvocationFailure].ok(
    LedgerWaitResponse(value: request.value, thread: threadNumber(), note: note)
  )

proc `seal`(
    m: Ledger, request: LedgerSealRequest
): Result[LedgerSealResponse, InvocationFailure] =
  var sealed = newSeq[byte](request.secret.len)
  for i, b in request.secret:
    sealed[sealed.high - i] = b xor 0x5A
  ok(LedgerSealResponse(sealed: sealed))

exportLedgerModule(Ledger)
