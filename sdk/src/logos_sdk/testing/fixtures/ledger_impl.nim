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
## cancelled. `seal` (marked) returns its secret reversed and masked. Every
## response names its handler's thread.

{.used.} # imported by the tests for the C symbols it exports
import std/[atomics, tables]
import ../generated/ledger_module_kit

{.compile: "foreign_lib.c".}

proc foreignPost(
  poster: pointer, fn: PostFn, threads, count: cint
): cint {.importc: "lcn_foreign_post", cdecl, gcsafe, raises: [].}

type Ledger* = ref object
  services*: ModuleServices
  entries: Table[string, uint64]
  keys: seq[string]
  kept: Invocation

var
  destroyed*: Atomic[int] ## instances `destroyModule` has seen
  posts*: Atomic[int] ## callbacks foreign threads posted that ran
  postThreads*: Atomic[int] ## how many of them did not run on a module thread
  probeHook*: proc(m: Ledger, value: uint64): string {.nimcall, gcsafe, raises: [].}
    ## what `probe` 8 calls; the test sets it

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
  Result[Ledger, InvocationFailure].ok(Ledger(services: init.services))

proc destroyModule(m: Ledger) =
  m.kept = nil
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
  discard m.services.publish(LedgerPostedEvent(key: request.key, total: total))
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
