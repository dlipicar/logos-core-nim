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
## and ignores a cancellation (`noCancel`); 12 calls `meter.read` of channel
## `value` through that handle and ignores a cancellation (`noCancel`), so its
## handler outlives the unwinding of a destroy (G437). `seal` (marked)
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
## how many sleep now (`<cancelled> <sleeping>`); 24 starts a foreign C thread
## that posts a callback touching the instance until `destroyModule` stops it.
## For G438's leftover cases, `probe` 25 registers a pipe's read end with the
## module thread's dispatcher and never unregisters it; 26 does the same and
## closes it without unregistering it; 27 names the chronos the library was
## built with (`main line` once it has `closeThreadDispatcher`, else `4.4.1`).
## For G440's post gate, `probe` 28 answers this instance's poster value in
## decimal, and an `initModule` given the state directory `/refuse-poster`
## keeps its poster in `refusedPoster`, then fails. `probe` 29 answers how
## many registrations the module thread's dispatcher held when it was made (a
## test hook; `no hooks` in a library built without them). `probe` 30 has the
## next `destroyModule` replace the module thread's dispatcher (destroy mode
## 10), and 31 posts a null callback, so the kit's `die` aborts on the module
## thread.
##
## `destroyModule` is `async` [DECISIONS G437], and awaits only when the test
## set `destroyMode` before the destroy; every other destroy returns without
## yielding, as a synchronous one does.

{.used.} # imported by the tests for the C symbols it exports
import std/[atomics, os, strutils, tables]
import ../generated/[ledger_module_kit, meter_module_calls]
import ../../kit/routes

{.compile: "foreign_lib.c".}

proc foreignPost(
  poster: pointer, fn: PostFn, threads, count: cint
): cint {.importc: "lcn_foreign_post", cdecl, gcsafe, raises: [].}

proc foreignPostLater(
  poster: pointer, fn: PostFn, payload: pointer, delayMs: cint
): pointer {.importc: "lcn_foreign_post_later", cdecl, gcsafe, raises: [].}

proc foreignLaterJoin(
  later: pointer
) {.importc: "lcn_foreign_later_join", cdecl, gcsafe, raises: [].}

proc foreignStreamStart(
  poster: pointer, fn: PostFn, payload: pointer
): pointer {.importc: "lcn_foreign_stream_start", cdecl, gcsafe, raises: [].}

proc foreignStreamStop(
  stream: pointer
): clong {.importc: "lcn_foreign_stream_stop", cdecl, gcsafe, raises: [].}

when defined(posix):
  proc cPipe(fds: var array[2, cint]): cint {.importc: "pipe", header: "<unistd.h>".}
  proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}

proc leaveRegistered(closeIt: bool): string =
  ## [DECISIONS G438] A pipe's read end registered with this thread's
  ## dispatcher and never unregistered; closed too when `closeIt`.
  when defined(posix):
    var fds: array[2, cint]
    if cPipe(fds) != 0:
      return "no pipe"
    discard cClose(fds[1])
    if register2(AsyncFD(fds[0])).isErr:
      discard cClose(fds[0])
      return "not registered"
    if closeIt:
      discard cClose(fds[0])
    "registered"
  else:
    "posix only"

proc tick(arg: pointer) {.gcsafe, raises: [].} =
  discard setTimer(Moment.fromNow(2.milliseconds), tick)

proc replaceDispatcher(): string =
  ## [DECISIONS G438] What MODULE-KIT §3 forbids: this thread's dispatcher
  ## replaced by a new one, which a timer wakes every 2 ms so the kit still sees
  ## its stop. chronos's `setThreadDispatcher` requires an empty callback queue,
  ## which the queue's sentinel never leaves, so it is emptied around the call.
  let old = getThreadDispatcher()
  let queued = old.callbacks
  old.callbacks.clear()
  setThreadDispatcher(newDispatcher())
  old.callbacks = queued
  tick(nil)
  "replaced"

type
  FreedMark = object
    ## Counts its instance in `freed` when the instance's memory goes (orc and
    ## arc builds); a moved-from mark is not live.
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
    wake: Future[void] ## what a destroy mode awaits a foreign post for
    stream: pointer ## the foreign stream `probe` 24 started
    streamed: int ## its callbacks that ran

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
  destroyMode*: Atomic[int]
    ## [DECISIONS G437] What the next `destroyModule` awaits, set by the test and
    ## taken back to 0 by that destroy: 0 nothing; 1 a callback a foreign thread
    ## posts 50 ms later; 2 `meter.read` of channel 7 through `invokeAsync`; 3
    ## `publishAsync`; 4 nothing, after two foreign threads posted 10 callbacks
    ## each; 5 as 1, 300 ms later, then reads what its handlers saw; 6 until a
    ## `wait` 12 handler finished; 7 as 1, 100 ms later. Each wait is bounded by
    ## 5 s. Every mode then stops `probe` 24's stream. [DECISIONS G440] Two
    ## modes break the module's duty on purpose: 8 leaves its wrapped route
    ## handle, subscription and prepared call unreleased (in `leftRoute` and
    ## `leftCall`), and 9 leaves `probe` 24's stream running (in `leftStream`,
    ## for `stopLeftStream`). [DECISIONS G438] 10 replaces the module thread's
    ## dispatcher (`replaceDispatcher`).
  destroyStarted*: Atomic[bool] ## a `destroyModule` began
  destroyReturned*: Atomic[bool] ## a `destroyModule` returned
  streamed*: Atomic[int] ## stream callbacks that ran
  streamedDuring*: Atomic[int] ## of them, while `destroyModule` ran
  lateCalls*: Atomic[int] ## of them, after `destroyModule` returned
  residualDone*: Atomic[int] ## `wait` 12 handlers that finished
  refusedPoster*: Atomic[pointer] ## the poster a failed `initModule` gave away
  leftRoute*: RouteHandle ## destroy mode 8: the handle left unreleased
  leftCall*: PreparedCall ## destroy mode 8: the call left unreleased
  leftStream*: Atomic[pointer] ## destroy mode 9: the stream left running
  destroyNoteLen: Atomic[int]
  destroyNoteText: array[64, char]
    ## what the last `destroyModule` noted: plain memory, read on the test's thread

when defined(gcOrc) or defined(gcArc) or defined(gcAtomicArc):
  # Only where the count is checked: Nim 2.2 refuses this `=destroy` form under
  # refc (it asks for `var T`), so refc builds, test_kit_mixed's and
  # test_kit_dylib's refc libraries among them, count nothing.
  proc `=destroy`(m: FreedMark) =
    if m.live:
      freed += 1

  proc `=copy`(a: var FreedMark, b: FreedMark) {.error.}

proc threadNumber(): uint64 =
  uint64(getThreadId())

proc setDestroyNote(s: string) =
  let n = min(s.len, destroyNoteText.len)
  {.cast(gcsafe).}:
    for i in 0 ..< n:
      destroyNoteText[i] = s[i]
  destroyNoteLen.store(n)

proc destroyNote*(): string =
  ## What the last `destroyModule` noted; read once the destroy returned.
  let n = destroyNoteLen.load
  result = newString(n)
  {.cast(gcsafe).}:
    for i in 0 ..< n:
      result[i] = destroyNoteText[i]

proc initModule(
    _: type Ledger, init: ModuleInit
): Future[Result[Ledger, InvocationFailure]] {.async: (raises: []).} =
  if init.stateDir == Opt.some("/refuse"): # refuse to start
    return Result[Ledger, InvocationFailure].err(
      failure(ecModule, "the state directory says no")
    )
  if init.stateDir == Opt.some("/refuse-poster"): # give the poster away, then fail
    refusedPoster.store(cast[pointer](init.services.poster))
    return Result[Ledger, InvocationFailure].err(
      failure(ecModule, "the state directory says no, after the poster went")
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

proc onPosted(payload: pointer) {.cdecl, gcsafe, raises: [].} =
  if not onConfinedThread():
    postThreads += 1
  posts += 1

proc onWoken(payload: pointer) {.cdecl, gcsafe, raises: [].} =
  let m = cast[Ledger](payload)
  posts += 1
  if not m.wake.isNil and not m.wake.finished():
    m.wake.complete()

proc onStreamed(payload: pointer) {.cdecl, gcsafe, raises: [].} =
  let m = cast[Ledger](payload)
  inc m.streamed # touches the instance
  streamed += 1
  if destroyReturned.load:
    lateCalls += 1
  elif destroyStarted.load:
    streamedDuring += 1

proc within5s(f: FutureBase): Future[bool] {.async: (raises: []).} =
  ## Whether `f` finished within 5 s. Unlike `withTimeout`, it never cancels `f`
  ## and waits for that: a call whose completion was dropped would never end.
  let guard = sleepAsync(5.seconds)
  try:
    discard await race(f, guard)
  except CancelledError:
    discard
  guard.cancelSoon()
  f.finished()

proc awaitWake(m: Ledger, delayMs: int): Future[bool] {.async: (raises: []).} =
  ## A callback a foreign thread posts `delayMs` later, awaited for up to 5 s.
  m.wake = newFuture[void]("ledger wake")
  let later = foreignPostLater(
    cast[pointer](m.services.poster), onWoken, cast[pointer](m), cint(delayMs)
  )
  if later.isNil:
    return false
  let woke = await within5s(m.wake)
  foreignLaterJoin(later)
  woke

proc readThrough(m: Ledger): Future[string] {.async: (raises: []).} =
  ## `meter.read` of channel 7 through `invokeAsync`, awaited for up to 5 s.
  if m.route.isNil:
    return "no route"
  let f = m.route.invokeAsync(MeterReadRequest(channel: 7))
  if not await within5s(f):
    return "guard"
  try:
    let r = f.read()
    if r.isOk:
      "ok:" & r.unsafeGet.label
    else:
      $r.unsafeError.code
  except CatchableError:
    "failed"

proc seenNote(m: Ledger): string =
  var values: seq[string]
  for v in m.seen:
    values.add($v)
  values.join(",")

proc destroyModule(m: Ledger) {.async: (raises: []).} =
  destroyStarted.store(true)
  var note = ""
  case destroyMode.exchange(0)
  of 1:
    note = "woke=" & $(await m.awaitWake(50))
  of 2:
    note = await m.readThrough()
  of 3:
    let f = m.services.publishAsync(LedgerPostedEvent(key: "destroy", total: 1))
    note =
      if not await within5s(f):
        "guard"
      else:
        try:
          statusNote(f.read())
        except CatchableError:
          "failed"
  of 4:
    let poster = cast[pointer](m.services.poster)
    note = (if foreignPost(poster, onPosted, 2, 10) == 0: "posted" else: "no threads")
  of 5:
    note = "woke=" & $(await m.awaitWake(300)) & " seen=" & m.seenNote
  of 6:
    var waited = 0
    while residualDone.load == 0 and waited < 5000:
      try:
        await sleepAsync(10.milliseconds)
      except CancelledError:
        break
      waited += 10
    note = "residual=" & $residualDone.load
  of 7:
    note = "woke=" & $(await m.awaitWake(100))
  of 8:
    {.cast(gcsafe).}:
      leftRoute = m.route
      leftCall = m.call
    m.route = nil
    m.call = PreparedCall()
    note = "left"
  of 9:
    leftStream.store(m.stream)
    m.stream = nil
    note = "streaming"
  of 10:
    note = replaceDispatcher()
  else:
    discard
  if not m.stream.isNil:
    discard foreignStreamStop(m.stream)
    m.stream = nil
  m.kept = nil
  if not m.call.isNil:
    discard m.call.release()
  if not m.set.isNil:
    discard m.set.close() # the route it holds too
  elif not m.route.isNil:
    discard m.route.release()
  destroyed += 1
  setDestroyNote(note)
  destroyReturned.store(true)

proc stopLeftStream*(): int =
  ## [DECISIONS G440] Stops the stream destroy mode 9 left running: how many
  ## posts it made, -1 when there was none.
  let s = leftStream.exchange(nil)
  if s.isNil:
    -1
  else:
    int(foreignStreamStop(s))

proc postFromNim*(poster: pointer) =
  ## [DECISIONS G440] One `post` of a counted callback through `poster`.
  post(Poster(poster), onPosted, nil)

proc postFromC*(poster: pointer): bool =
  ## [DECISIONS G440] One `lcn_kit_post` of a counted callback through
  ## `poster`, from a foreign C thread this joins.
  let later = foreignPostLater(poster, onPosted, nil, 0)
  if later.isNil:
    return false
  foreignLaterJoin(later)
  true

proc ledgerOf(user: pointer): Ledger =
  if destroyReturned.load:
    lateCalls += 1 # [DECISIONS G440] a handler of an instance already gone
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
  of 24:
    if m.stream.isNil:
      m.stream = foreignStreamStart(
        cast[pointer](m.services.poster), onStreamed, cast[pointer](m)
      )
    note = (if m.stream.isNil: "no stream" else: "streaming")
  of 25:
    note = leaveRegistered(closeIt = false)
  of 26:
    note = leaveRegistered(closeIt = true)
  of 27:
    note = (when declared(closeThreadDispatcher): "main line" else: "4.4.1")
  of 28:
    note = $cast[uint](cast[pointer](m.services.poster))
  of 29:
    note = (when declared(notedRegistrations): $notedRegistrations()
    else: "no hooks")
  of 30:
    destroyMode.store(10)
    note = "armed"
  of 31:
    m.services.poster.post(nil, nil)
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
  of 12:
    if m.route.isNil:
      note = "no route"
    else:
      let r = await noCancel(
        m.route.invokeAsync(MeterReadRequest(channel: uint32(request.value)))
      )
      note = (if r.isOk: "ok:" & r.unsafeGet.label else: $r.unsafeError.code)
      residualDone += 1
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
