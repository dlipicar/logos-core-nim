## lcn-gen's thread-confined module kit [IMPL] (DECISIONS G335-G339), in
## process: the ledger fixture (`testing/fixtures/ledger_impl.nim`) is called
## through its exported C symbols, as an ABI caller makes the calls, and every
## entry that uses the instance runs on the context's module thread. The
## Runtime stand-in here gives each caller an identity of its own and lets the
## publish callbacks re-enter the module, as a direct subscriber does
## (INTERFACE l.1918-1928, IFC-0281/0282). Its deferred provider surface
## (`_MODULE_async_api`, G338) is driven with provider invocations the test
## builds in fixed storage, as a Runtime does.

import std/[os, strutils, times]
import unittest2
from chronos import finished, value
import logos_sdk/codegen/[callrt, confinedcalls, consumert]
from logos_sdk/codegen/confinedrt import
  packGate, unpackGate, gateNext, GateMaxGen, GateMaxSlots, failSignalClose,
  failedSignalFd, failInitAt
import logos_sdk/testing/kitruntime
import logos_sdk/testing/fixtures/ledger_impl
import
  logos_sdk/testing/generated/
    [ledger_module_types, meter_module_types, meter_module_calls]
import ./support/fakeprovider

# The exported symbols, as an ABI caller declares them -------------------------------

proc ledgerInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.importc: "logos_ledger_module_MODULE_init", cdecl, gcsafe, raises: [].}

proc ledgerDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_ledger_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc ledgerFree(
  module: ptr LogosModuleContext, p: pointer
) {.importc: "logos_ledger_module_MODULE_free", cdecl, gcsafe, raises: [].}

proc ledgerDispatch(
  module: ptr LogosModuleContext,
  methodName: cstring,
  params: ptr UncheckedArray[uint8],
  paramsLen: csize_t,
  outResponse: ptr ptr UncheckedArray[uint8],
  outResponseLen: ptr csize_t,
): LogosResult {.
  importc: "logos_ledger_module_MODULE_dispatch", cdecl, gcsafe, raises: []
.}

proc ledgerPost(
  module: ptr LogosModuleContext,
  owner: ptr LogosResponseOwner,
  amount: uint64,
  key: cstring,
  thread: ptr uint64,
  total: ptr uint64,
): LogosResult {.
  importc: "logos_ledger_module_CALL_ledger_Post", cdecl, gcsafe, raises: []
.}

proc ledgerWait(
  module: ptr LogosModuleContext,
  owner: ptr LogosResponseOwner,
  channel: uint32,
  millis: uint32,
  value: uint64,
  note: ptr cstring,
  thread: ptr uint64,
  outValue: ptr uint64,
): LogosResult {.
  importc: "logos_ledger_module_CALL_ledger_Wait", cdecl, gcsafe, raises: []
.}

proc ledgerAsyncApi(): ptr LogosAsyncProviderApi {.
  importc: "logos_ledger_module_MODULE_async_api", cdecl, gcsafe, raises: []
.}

proc ledgerSeal(
  module: ptr LogosModuleContext,
  owner: ptr LogosResponseOwner,
  secret: ptr UncheckedArray[uint8],
  secretLen: csize_t,
  sealed: ptr ptr UncheckedArray[uint8],
  sealedLen: ptr csize_t,
): LogosResult {.
  importc: "logos_ledger_module_CALL_ledger_Seal", cdecl, gcsafe, raises: []
.}

# A Runtime stand-in whose callers have identities -------------------------------------

type
  Who = object
    id: cstring ## the caller's module instance

  Note = object
    ## Text written on one thread and read on another: no GC'd memory, which
    ## refc's per-thread heaps would not let another thread touch.
    len: int
    text: array[64, char]

  Seen = object ## one event a publish callback got
    scoped: bool ## the context's callback, not the instance's
    key: Note
    thread: uint64

const seenCap = 4096

var
  reenterModule: Atomic[pointer]
    ## the module a publish callback re-enters, as a direct subscriber does; nil for none
  reentries: Atomic[int] ## re-entries that read the re-entering caller
  reentryFailures: Atomic[int]
  publishDelay: Atomic[int] ## milliseconds each callback waits before it records
  holdPublish: Atomic[bool] ## the instance callback waits while this is set
  holding: Atomic[bool] ## the instance callback is waiting on `holdPublish`
  callbackCode: Atomic[int32] ## what the instance callback returns
  seenLock: Lock
  seenLen: int
  seen: array[seenCap, Seen]
initLock(seenLock)

proc note(s: string): Note =
  result.len = min(s.len, result.text.len)
  for i in 0 ..< result.len:
    result.text[i] = s[i]

proc `$`(n: Note): string =
  result = newString(n.len)
  for i in 0 ..< n.len:
    result[i] = n.text[i]

proc here(): uint64 =
  uint64(getThreadId())

proc view(s: cstring): LogosUtf8View =
  LogosUtf8View(data: cast[ptr UncheckedArray[uint8]](s), len: csize_t(s.len))

proc whoCaller(
    invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
): LogosResult {.cdecl, gcsafe, raises: [].} =
  let who = cast[ptr Who](invocation.state)
  outCaller[] = LogosCallerView(
    kind: CallerModule,
    runtimeInstanceId: view(cstring(runtimeId)),
    moduleInstanceId: view(who.id),
  )
  LogosResult()

proc see(scoped: bool, name: cstring, data: ptr UncheckedArray[uint8], len: csize_t) =
  var bytes = newSeq[byte](int(len))
  for i in 0 ..< int(len):
    bytes[i] = data[i]
  let key =
    if $name == "ledger.posted_event":
      LedgerPostedEvent.decode(bytes).get.key
    else:
      $name
  {.cast(gcsafe).}:
    withLock seenLock:
      doAssert seenLen < seenCap
      seen[seenLen] = Seen(scoped: scoped, key: note(key), thread: here())
      inc seenLen

proc whoPublish(
  invocation: ptr LogosInvocationContext,
  eventName: cstring,
  cborData: ptr UncheckedArray[uint8],
  cborDataLen: csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].}

var
  whoA = Who(id: "caller-a")
  whoB = Who(id: "caller-b")
  whoC = Who(id: "caller-c")
  whoR = Who(id: "reentry")
  whoVtable = LogosInvocationContextVtable(
    abiVersion: 1,
    structSize: csize_t(sizeof(LogosInvocationContextVtable)),
    caller: whoCaller,
    isCancelled: cancelledOp,
    publish: whoPublish,
  )
  ctxA = LogosInvocationContext(vtable: addr whoVtable, state: addr whoA)
  ctxB = LogosInvocationContext(vtable: addr whoVtable, state: addr whoB)
  ctxC = LogosInvocationContext(vtable: addr whoVtable, state: addr whoC)
  ctxR = LogosInvocationContext(vtable: addr whoVtable, state: addr whoR)

proc request[T](v: T): seq[byte] =
  encode(v).get

proc probe(
    ctx: ptr LogosModuleContext, channel: uint32, value = 0'u64
): (ErrorCode, LedgerProbeResponse) {.gcsafe.} =
  let c = call(
    ledgerDispatch,
    ledgerFree,
    ctx,
    "probe",
    request(LedgerProbeRequest(channel: channel, value: value)),
  )
  if c.code != ecOk:
    return (c.code, LedgerProbeResponse())
  (ecOk, LedgerProbeResponse.decode(c.response).get)

proc wait(
    ctx: ptr LogosModuleContext, channel: uint32, millis = 0'u32, value = 0'u64
): (ErrorCode, LedgerWaitResponse) {.gcsafe.} =
  let c = call(
    ledgerDispatch,
    ledgerFree,
    ctx,
    "wait",
    request(LedgerWaitRequest(channel: channel, millis: millis, value: value)),
  )
  if c.code != ecOk:
    return (c.code, LedgerWaitResponse())
  (ecOk, LedgerWaitResponse.decode(c.response).get)

proc post(
    ctx: ptr LogosModuleContext, key: string, amount = 1'u64
): (ErrorCode, LedgerPostResponse) {.gcsafe.} =
  let c = call(
    ledgerDispatch,
    ledgerFree,
    ctx,
    "post",
    request(LedgerPostRequest(key: key, amount: amount)),
  )
  if c.code != ecOk:
    return (c.code, LedgerPostResponse())
  (ecOk, LedgerPostResponse.decode(c.response).get)

proc reenter() {.gcsafe, raises: [].} =
  ## A direct subscriber that calls back into the module from the callback's
  ## thread, with a caller of its own made current around the entry.
  let m = cast[ptr LogosModuleContext](reenterModule.load)
  if m == nil:
    return
  {.cast(gcsafe).}:
    let saved = activeContext
    activeContext = addr ctxR
    let (code, r) = probe(m, 1)
    activeContext = saved
  if code == ecOk and r.note == "reentry":
    reentries += 1
  else:
    reentryFailures += 1

proc instancePublish(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): CErrorCode {.cdecl, gcsafe, raises: [].} =
  while holdPublish.load:
    holding.store(true)
    sleep(1)
  holding.store(false)
  let d = publishDelay.load
  if d > 0:
    sleep(d)
  see(false, eventName, cborData, cborDataLen)
  reenter()
  CErrorCode(callbackCode.load)

proc whoPublish(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  let d = publishDelay.load
  if d > 0:
    sleep(d)
  see(true, eventName, cborData, cborDataLen)
  reenter()
  LogosResult()

proc ledgerInput(stateDir: cstring = nil): LogosModuleInitInput =
  result = input(stateDir = stateDir)
  result.publish = instancePublish

proc openLedger(): ptr LogosModuleContext =
  var inp = ledgerInput()
  let r = ledgerInit(addr inp, addr result)
  doAssert r.code == CErrorCode(0), "init failed: " & $r.code

proc resetRuntime() =
  reenterModule.store(nil)
  reentries.store(0)
  reentryFailures.store(0)
  publishDelay.store(0)
  holdPublish.store(false)
  callbackCode.store(0)
  cancelled.store(false)
  activeContext = nil
  probeHook = nil
  withLock seenLock:
    seenLen = 0

proc seenKeys(how: string): seq[string] =
  withLock seenLock:
    for i in 0 ..< seenLen:
      if seen[i].scoped == (how == "scoped"):
        result.add($seen[i].key)

proc seenCount(key: string): int =
  withLock seenLock:
    for i in 0 ..< seenLen:
      if $seen[i].key == key:
        inc result

proc seenThreads(key: string): seq[uint64] =
  withLock seenLock:
    for i in 0 ..< seenLen:
      if $seen[i].key == key:
        result.add(seen[i].thread)

proc clearOwner(owner: var LogosResponseOwner) =
  let previous = owner
  owner = LogosResponseOwner()
  if not previous.release.isNil:
    previous.release(previous.state)

proc openDescriptors(): int =
  when defined(linux):
    for _ in walkDir("/proc/self/fd"):
      inc result
  else:
    for _ in walkDir("/dev/fd"):
      inc result

when defined(posix):
  from std/posix import pipe, dup, dup2, close, read, fcntl, F_GETFD

  proc capturingStderr(body: proc()): string =
    ## What `body` writes on descriptor 2, up to 4 KiB.
    var fds: array[2, cint]
    doAssert pipe(fds) == 0
    let saved = dup(2)
    discard dup2(fds[1], 2)
    discard close(fds[1])
    try:
      body()
    finally:
      discard dup2(saved, 2)
      discard close(saved)
    var buf: array[4096, char]
    let n = read(fds[0], addr buf[0], buf.len)
    discard close(fds[0])
    if n > 0:
      result = newString(n)
      copyMem(addr result[0], addr buf[0], n)

# Threads the tests start ------------------------------------------------------------

const
  workers = 16
  rounds = 40

var
  shared: ptr LogosModuleContext
  workerIds: array[workers, string]
  workerWho: array[workers, Who]
  workerCtx: array[workers, LogosInvocationContext]
  workerFailures: Atomic[int]
  moduleThread: Atomic[uint64]
  ticket: Atomic[int]
  asyncDone: Atomic[int] ## the ticket the first async caller took when it returned
  asyncNote: array[2, Note]
  waitedRoom: Atomic[bool]
  roomNote: Note

for i in 0 ..< workers:
  workerIds[i] = "worker-" & $i
  workerWho[i] = Who(id: cstring(workerIds[i]))
  workerCtx[i] =
    LogosInvocationContext(vtable: addr whoVtable, state: addr workerWho[i])

const initFailureMessages = [
  "the post gate has no free slot", "the module's publisher thread did not start",
  "the module thread did not start",
]

var initFailures: array[3, tuple[code: int, named, noContext: bool, before, after: int]]

proc failingInit(step: int) {.thread.} =
  ## [DECISIONS G438] On a thread that never had a chronos dispatcher: an init
  ## failing at `step` (`failInitAt`), and the open descriptors around it.
  {.cast(gcsafe).}:
    var inp = ledgerInput()
    var ctx: ptr LogosModuleContext
    failInitAt = step
    let before = openDescriptors()
    let r = ledgerInit(addr inp, addr ctx)
    let after = openDescriptors()
    initFailures[step - 1] = (
      int(r.code),
      r.message != nil and $r.message == initFailureMessages[step - 1],
      ctx == nil,
      before,
      after,
    )

proc sameModuleThread(t: uint64) =
  var expected = 0'u64
  if not moduleThread.compareExchange(expected, t) and expected != t:
    workerFailures += 1

proc worker(i: int) {.thread.} =
  {.cast(gcsafe).}:
    activeContext = addr workerCtx[i]
    let key = workerIds[i]
    for r in 0 ..< rounds:
      if r mod 2 == 0:
        let (code, resp) = post(shared, key)
        if code != ecOk or resp.total != uint64(r + 1):
          workerFailures += 1
        sameModuleThread(resp.thread)
      else:
        var owner: LogosResponseOwner
        var total, thread: uint64
        if ledgerPost(shared, addr owner, 1, cstring(key), addr thread, addr total).code !=
            CErrorCode(0) or total != uint64(r + 1):
          workerFailures += 1
        sameModuleThread(thread)
        clearOwner(owner)
      if r mod 8 == 3:
        # An async handler: it reads its own caller after an await, while the
        # other workers' jobs run on the same thread.
        let (code, w) = wait(shared, 1, millis = 1)
        if code != ecOk or w.note != key:
          workerFailures += 1
      if r mod 8 == 5:
        let (code, p) = probe(shared, 1)
        if code != ecOk or p.note != key:
          workerFailures += 1
    activeContext = nil

proc asyncCaller(i: int) {.thread.} =
  ## One async handler that sleeps, then reads its caller.
  {.cast(gcsafe).}:
    activeContext =
      if i == 0:
        addr ctxA
      else:
        addr ctxB
    let (code, w) = wait(shared, 1, millis = (if i == 0: 60'u32 else: 20'u32))
    asyncNote[i] = note(
      if code == ecOk:
        w.note
      else:
        $code
    )
    if i == 0:
      asyncDone.store(ticket.fetchAdd(1))
    activeContext = nil

proc roomCaller(i: int) {.thread.} =
  {.cast(gcsafe).}:
    let (code, w) = wait(shared, 3, value = 7)
    roomNote = note(
      if code == ecOk:
        w.note
      else:
        $code
    )
    waitedRoom.store(true)

proc inlineEntry(m: Ledger, value: uint64): string {.nimcall, gcsafe, raises: [].} =
  ## The module's own entry called on its module thread, as a Runtime makes it:
  ## a caller of its own current on that thread around the entry.
  {.cast(gcsafe).}:
    let saved = activeContext
    activeContext = addr ctxC
    result =
      if value == 0:
        let (code, r) = probe(shared, 1)
        if code == ecOk:
          r.note
        else:
          $code
      else:
        let (code, w) = wait(shared, 1, millis = uint32(value))
        if code == ecOk:
          w.note
        else:
          $code
    activeContext = saved

# A route binding the test drives (DECISIONS G339) ----------------------------------
#
# The ledger wraps it with its kit's dispatcher; the test delivers events, ends the
# subscription or the route and completes a prepared call from its own threads, as
# a binding's threads do.

type FakeSub = object
  id: uint64
  handler: LogosEventHandler
  user: pointer
  active: bool
  ended: bool

var
  fakeLock: Lock
  fakeSubs: array[8, FakeSub]
  fakeNextId: uint64
  fakeEnd: LogosRouteEndHandler
  fakeEndUser: pointer
  fakeSubEnd: LogosSubscriptionEndHandler
  fakeSubEndUser: pointer
  fakeCallbacks: LogosAsyncCallbacks
  fakeState: byte
  fakeReleased: Atomic[bool]
  fakeReleases: Atomic[int] ## the route handle's `release` calls
  fakeLateOps: Atomic[int] ## route operations once its `release` ran
  fakeUnsubscribes: Atomic[int]
  fakeUnsubscribesInside: Atomic[int] ## made from inside a delivery
  fakeCompleteInSubmit: Atomic[bool]
  fakeCallLive: Atomic[bool] ## the latest prepared call is not released
  fakeLateCallUses: Atomic[int] ## `submit` or `cancel` of a released call
  fakeSubmits: Atomic[int]
  fakeReadyAtSubmit: Atomic[int] ## submits whose call had its callback and user state
  fakeCallReleases: Atomic[int]
  fakeCancels: Atomic[int]
  fakeCancelCompletes: Atomic[bool] ## `cancel` completes the call CANCELLED
  fakeTimeout: Atomic[int] ## the latest prepared call's deadline, 0 for none
  fakePrepares: Atomic[int] ## calls prepared
  fakeNullOnEntry: Atomic[int] ## prepares whose output call was null on entry
  deliveries: Atomic[int] ## events `deliver` handed to a subscription
  ownerReleases: Atomic[int]
  ownerReleaseThread: Atomic[uint64]
  delivering {.threadvar.}: bool
initLock(fakeLock)

proc routeOp() =
  ## Every route operation but `release` notes whether the handle was released.
  if fakeReleased.load:
    fakeLateOps += 1

proc fakeCallOp(
    route: ptr LogosRouteHandle,
    m: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResponse: ptr ptr UncheckedArray[uint8],
    outResponseLen: ptr csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  routeOp()
  LogosResult(code: CErrorCode(ord(ecModule)))

proc fakeReleaseResponseOp(
    route: ptr LogosRouteHandle, r: ptr UncheckedArray[uint8], n: csize_t
) {.cdecl, gcsafe, raises: [].} =
  routeOp()

proc fakeSubscribeOp(
    route: ptr LogosRouteHandle,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  routeOp()
  {.cast(gcsafe).}:
    withLock fakeLock:
      for f in fakeSubs.mitems:
        if not f.active and not f.ended:
          inc fakeNextId
          f = FakeSub(id: fakeNextId, handler: handler, user: userData, active: true)
          outId[] = fakeNextId
          return LogosResult()
  LogosResult(code: CErrorCode(ord(ecModule)))

proc fakeUnsubscribeOp(
    route: ptr LogosRouteHandle, id: LogosSubscriptionId
): LogosResult {.cdecl, gcsafe, raises: [].} =
  routeOp()
  fakeUnsubscribes += 1
  if delivering:
    fakeUnsubscribesInside += 1
  {.cast(gcsafe).}:
    withLock fakeLock:
      for f in fakeSubs.mitems:
        if f.id == id and (f.active or f.ended):
          f = FakeSub()
          return LogosResult()
  LogosResult(code: CErrorCode(ord(ecInvalidParams)))

proc fakeReleaseOp(route: ptr LogosRouteHandle) {.cdecl, gcsafe, raises: [].} =
  fakeReleases += 1
  fakeReleased.store(true)

proc ownerRelease(state: pointer) {.cdecl, gcsafe, raises: [].} =
  ownerReleases += 1
  ownerReleaseThread.store(here())

proc completeFake(label: string) {.gcsafe.} =
  ## The prepared call's one completion, from this thread, with an owner.
  var response =
    encode(MeterReadResponse(label: label, reading: MeterReading(value: 1))).get
  let owner = LogosResponseOwner(state: addr fakeState, release: ownerRelease)
  {.cast(gcsafe).}:
    let cb = fakeCallbacks
  cb.complete(
    cb.userData,
    LogosResult(),
    cast[ptr UncheckedArray[uint8]](addr response[0]),
    csize_t(response.len),
    owner,
  )

proc fakeSubmitOp(call: ptr LogosAsyncCall) {.cdecl, gcsafe, raises: [].} =
  fakeSubmits += 1
  if not fakeCallLive.load:
    fakeLateCallUses += 1
  {.cast(gcsafe).}:
    let cb = fakeCallbacks
  if cb.complete != nil and cb.userData != nil:
    fakeReadyAtSubmit += 1
  if fakeCompleteInSubmit.load:
    completeFake("inline")

proc fakeCancelOp(call: ptr LogosAsyncCall) {.cdecl, gcsafe, raises: [].} =
  fakeCancels += 1
  if not fakeCallLive.load:
    fakeLateCallUses += 1
  if fakeCancelCompletes.load:
    {.cast(gcsafe).}:
      let cb = fakeCallbacks
    cb.complete(
      cb.userData,
      LogosResult(code: CErrorCode(ord(ecCancelled))),
      nil,
      0,
      LogosResponseOwner(),
    )

proc fakeCallReleaseOp(call: ptr LogosAsyncCall) {.cdecl, gcsafe, raises: [].} =
  fakeCallReleases += 1
  fakeCallLive.store(false)

var fakeCallVtable = LogosAsyncCallVtable(
  abiVersion: AsyncCallAbiVersion,
  structSize: csize_t(sizeof(LogosAsyncCallVtable)),
  submit: fakeSubmitOp,
  cancel: fakeCancelOp,
  release: fakeCallReleaseOp,
)

proc fakePrepareOp(
    route: ptr LogosRouteHandle,
    m: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  routeOp()
  if outCall.vtable == nil and outCall.state == nil:
    fakeNullOnEntry += 1
  {.cast(gcsafe).}:
    fakeCallbacks = callbacks[]
    outCall[] = LogosAsyncCall(vtable: addr fakeCallVtable, state: addr fakeState)
  fakeCallLive.store(true)
  fakePrepares += 1
  fakeTimeout.store(
    if options.hasTimeout:
      int(options.timeoutMs)
    else:
      0
  )
  LogosResult()

proc fakeObserveEndOp(
    route: ptr LogosRouteHandle, handler: LogosRouteEndHandler, userData: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  routeOp()
  {.cast(gcsafe).}:
    fakeEnd = handler
    fakeEndUser = userData
  LogosResult()

proc fakeObserveSubEndOp(
    route: ptr LogosRouteHandle, handler: LogosSubscriptionEndHandler, userData: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  routeOp()
  {.cast(gcsafe).}:
    fakeSubEnd = handler
    fakeSubEndUser = userData
  LogosResult()

var fakeVtable = LogosRouteVtable(
  abiVersion: RouteVtableAbiVersion,
  structSize: csize_t(sizeof(LogosRouteVtable)),
  call: fakeCallOp,
  releaseResponse: fakeReleaseResponseOp,
  subscribe: fakeSubscribeOp,
  unsubscribe: fakeUnsubscribeOp,
  release: fakeReleaseOp,
  prepareCall: fakePrepareOp,
  observeEnd: fakeObserveEndOp,
  observeSubscriptionEnd: fakeObserveSubEndOp,
)

proc resetFake() =
  withLock fakeLock:
    for f in fakeSubs.mitems:
      f = FakeSub()
  fakeEnd = nil
  fakeSubEnd = nil
  fakeReleased.store(false)
  fakeReleases.store(0)
  fakeLateOps.store(0)
  fakeUnsubscribes.store(0)
  fakeUnsubscribesInside.store(0)
  fakeCompleteInSubmit.store(false)
  fakeCallLive.store(false)
  fakeLateCallUses.store(0)
  fakeSubmits.store(0)
  fakeReadyAtSubmit.store(0)
  fakeCallReleases.store(0)
  fakeCancels.store(0)
  fakeCancelCompletes.store(false)
  fakeTimeout.store(0)
  fakePrepares.store(0)
  fakeNullOnEntry.store(0)
  deliveries.store(0)
  ownerReleases.store(0)
  routeToWrap = LogosRouteHandle(vtable: addr fakeVtable, state: addr fakeState)

proc deliver(value: uint64) {.gcsafe.} =
  ## `meter.changed_event` to every active subscription, from this thread.
  var payload = encode(MeterChangedEvent(value: value)).get
  var targets: seq[(LogosEventHandler, pointer)]
  {.cast(gcsafe).}:
    withLock fakeLock:
      for f in fakeSubs:
        if f.active:
          targets.add((f.handler, f.user))
  for (handler, user) in targets:
    deliveries += 1
    delivering = true
    handler(
      "meter.changed_event",
      cast[ptr UncheckedArray[uint8]](addr payload[0]),
      csize_t(payload.len),
      user,
    )
    delivering = false

proc endSubscription(reason: ErrorCode) =
  ## The binding ends the first active subscription (INTERFACE l.1472-1483).
  var id: uint64
  withLock fakeLock:
    for f in fakeSubs.mitems:
      if f.active:
        f.active = false
        f.ended = true
        id = f.id
        break
  fakeSubEnd(id, CErrorCode(ord(reason)), fakeSubEndUser)

proc endRoute(reason: ErrorCode) =
  fakeEnd(CErrorCode(ord(reason)), fakeEndUser)

var
  gate: Atomic[bool]
  gateEntered: Atomic[bool]

proc holdHook(m: Ledger, value: uint64): string {.nimcall, gcsafe, raises: [].} =
  ## Keeps the module thread busy until the test opens the gate.
  gateEntered.store(true)
  while gate.load:
    sleep(1)
  "held"

proc holder(i: int) {.thread.} =
  {.cast(gcsafe).}:
    discard probe(shared, 8)

proc deliverInsideHook(
    m: Ledger, value: uint64
): string {.nimcall, gcsafe, raises: [].} =
  ## On the module thread: the binding delivers here (INTERFACE l.1405), then the
  ## handler unsubscribes before those deliveries ran.
  let before = m.seenCount
  deliver(5)
  deliver(6)
  let ran = m.seenCount - before
  $ran & " " & m.unsubscribeChanged()

proc report(ctx: ptr LogosModuleContext): string =
  probe(ctx, 14)[1].note

proc resetDestroy() =
  ## The fixture's destroy modes and counters (DECISIONS G437).
  destroyMode.store(0)
  destroyStarted.store(false)
  destroyReturned.store(false)
  streamed.store(0)
  streamedDuring.store(0)
  lateCalls.store(0)
  residualDone.store(0)
  posts.store(0)
  postThreads.store(0)

proc completeInDestroy(a: (int, int)) {.thread.} =
  ## Completes the latest prepared call `a[0]` ms after `destroyModule` began,
  ## once `a[1]` calls were prepared, as a binding's thread does.
  let (delayMs, prepared) = a
  for _ in 0 ..< 20_000:
    if destroyStarted.load and fakePrepares.load >= prepared:
      break
    sleep(1)
  sleep(delayMs)
  completeFake("destroy")

var deliveredInDestroy: Atomic[int]

proc deliverInDestroy(i: int) {.thread.} =
  ## Two `meter.changed_event`s once `destroyModule` began.
  for _ in 0 ..< 20_000:
    if destroyStarted.load:
      break
    sleep(1)
  let before = deliveries.load
  deliver(5)
  deliver(6)
  deliveredInDestroy.store(deliveries.load - before)

proc streamedAtLeast(n: int): bool =
  for _ in 0 ..< 5000:
    if streamed.load >= n:
      return true
    sleep(1)
  false

# Provider invocations the test builds (DECISIONS G338) -------------------------------
#
# `support/fakeprovider`: the context's `publish` is the stand-in's, and each
# completion notes how many scoped publications were seen by then.

proc scopedSeen(): int =
  {.cast(gcsafe).}:
    withLock seenLock:
      for i in 0 ..< seenLen:
        if seen[i].scoped:
          inc result

fakePublish = whoPublish
completionProbe = scopedSeen

proc submit(ctx: ptr LogosModuleContext, fi: ptr FakeInvocation) {.gcsafe.} =
  submit(ledgerAsyncApi(), ctx, fi)

proc cancel(ctx: ptr LogosModuleContext, fi: ptr FakeInvocation) {.gcsafe.} =
  cancel(ledgerAsyncApi(), ctx, fi)

proc deferred(
    ctx: ptr LogosModuleContext,
    i: int,
    bare: string,
    params: openArray[byte],
    id = "deferred",
): ptr FakeInvocation =
  ## One submitted invocation, once it was completed and released.
  result = prepareFake(i, bare, params, id)
  submit(ctx, result)
  doAssert result.settledIn(), "the invocation was not released"

var apiSeen: Atomic[pointer]

proc apiReader(i: int) {.thread.} =
  apiSeen.store(ledgerAsyncApi())

proc ownerClearer(fi: ptr FakeInvocation) {.thread.} =
  clearFake(fi)

proc canceller(t: int) {.thread.} =
  ## Cancels the invocations `k` with `k mod 4 == t` at once, from its thread.
  {.cast(gcsafe).}:
    for k in countup(t, 63, 4):
      if k mod 2 == 0:
        cancel(shared, addr fakes[k])
      if k mod 3 == 0:
        sleep(1)

proc submitter(t: int) {.thread.} =
  ## Submits the invocations `k` with `k mod 4 == t`, then dispatches.
  {.cast(gcsafe).}:
    activeContext = addr ctxB
    for k in countup(t, 63, 4):
      submit(shared, addr fakes[k])
      if k mod 5 == 0:
        if probe(shared, 1)[1].note != "caller-b":
          workerFailures += 1
    activeContext = nil

# Tests --------------------------------------------------------------------------------

suite "confined kit: handoff (DECISIONS G335)":
  setup:
    resetRuntime()

  test "[IMPL-DECISION G335] init, dispatch and typed calls run on one module thread, not the caller's":
    let ctx = openLedger()
    let (code, r) = probe(ctx, 1)
    check code == ecOk
    check r.thread != here()
    var owner: LogosResponseOwner
    var total, thread: uint64
    check ledgerPost(ctx, addr owner, 5, "a", addr thread, addr total).code ==
      CErrorCode(0)
    check total == 5
    check thread == r.thread
    clearOwner(owner)
    check ledgerPost(ctx, addr owner, 7, "a", addr thread, addr total).code ==
      CErrorCode(0)
    check total == 12
    clearOwner(owner)
    let (wcode, w) = wait(ctx, 1, millis = 1)
    check wcode == ecOk
    check w.thread == r.thread
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G335] a typed call to an async handler and to a marked one; the owner holds the outputs":
    let ctx = openLedger()
    activeContext = addr ctxA
    let base = arenaBlocks()
    var owner: LogosResponseOwner
    var note: cstring
    var thread, value: uint64
    check ledgerWait(ctx, addr owner, 1, 1, 9, addr note, addr thread, addr value).code ==
      CErrorCode(0)
    check $note == "caller-a"
    check value == 9
    check thread != here()
    check arenaBlocks() > base
    clearOwner(owner)
    check arenaBlocks() == base
    var secret = @[1'u8, 2, 3]
    var sealed: ptr UncheckedArray[uint8]
    var sealedLen: csize_t
    check ledgerSeal(
      ctx,
      addr owner,
      cast[ptr UncheckedArray[uint8]](addr secret[0]),
      csize_t(secret.len),
      addr sealed,
      addr sealedLen,
    ).code == CErrorCode(0)
    check sealedLen == 3
    check [sealed[0], sealed[1], sealed[2]] == [3'u8 xor 0x5A, 2 xor 0x5A, 1 xor 0x5A]
    clearOwner(owner)
    check arenaBlocks() == base
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G335] a failure's message is read on the calling thread":
    let ctx = openLedger()
    let c = call(
      ledgerDispatch,
      ledgerFree,
      ctx,
      "probe",
      request(LedgerProbeRequest(channel: 3, value: 0)),
    )
    check c.code == ecModule
    check c.status.error.message == Opt.some("probe 3 fails")
    let w = call(
      ledgerDispatch,
      ledgerFree,
      ctx,
      "wait",
      request(LedgerWaitRequest(channel: 5, millis: 0, value: 0)),
    )
    check w.code == ecModule
    check w.status.error.message == Opt.some("wait 5 fails")
    let unknown = call(ledgerDispatch, ledgerFree, ctx, "nothing", diag("{}"))
    check unknown.code == ecMethodNotFound
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G335] calls from 16 threads at once, plain, typed and async, each with its own caller":
    shared = openLedger()
    moduleThread.store(0)
    workerFailures.store(0)
    var threads: array[workers, Thread[int]]
    for i in 0 ..< workers:
      createThread(threads[i], worker, i)
    joinThreads(threads)
    check workerFailures.load == 0
    check moduleThread.load != 0 and moduleThread.load != here()
    for i in 0 ..< workers:
      let (code, r) = post(shared, workerIds[i], 0)
      check code == ecOk and r.total == rounds
    ledgerDestroy(shared)
    shared = nil

  test "[IMPL-DECISION G335] two contexts have two module threads and two instances":
    let one = openLedger()
    let two = openLedger()
    let (_, a) = post(one, "x", 3)
    let (_, b) = post(two, "x", 4)
    check a.total == 3 and b.total == 4
    check a.thread != b.thread
    check a.thread != here() and b.thread != here()
    ledgerDestroy(one)
    let (_, c) = post(two, "x", 1)
    check c.total == 5
    ledgerDestroy(two)

suite "confined kit: invocation context (DECISIONS G336)":
  setup:
    resetRuntime()

  test "[IMPL-DECISION G336] a plain handler reads its job's caller; an async task's plain API is NOT_READY":
    let ctx = openLedger()
    activeContext = addr ctxA
    let (_, r) = probe(ctx, 1)
    check r.note == "caller-a"
    let (_, w) = wait(ctx, 1, millis = 2)
    check w.note == "caller-a"
    let (_, w6) = wait(ctx, 6)
    check w6.note == $ecNotReady
    activeContext = nil
    let (_, none) = probe(ctx, 1)
    check none.note == $ecNotReady
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G336] isCancelled from a plain and from an async handler":
    let ctx = openLedger()
    activeContext = addr ctxA
    check probe(ctx, 4)[1].note == "live"
    check wait(ctx, 8)[1].note == "live"
    cancelled.store(true)
    check probe(ctx, 4)[1].note == "cancelled"
    check wait(ctx, 8)[1].note == "cancelled"
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G336] an Invocation is refused once its job ended":
    let ctx = openLedger()
    activeContext = addr ctxA
    let (_, w) = wait(ctx, 4)
    check w.note == "kept"
    let (_, r) = probe(ctx, 6)
    check r.note == $ecNotReady
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G336] two interleaved async handlers each see only their own caller":
    shared = openLedger()
    ticket.store(0)
    var threads: array[2, Thread[int]]
    createThread(threads[0], asyncCaller, 0)
    sleep(5)
    createThread(threads[1], asyncCaller, 1)
    joinThreads(threads)
    check $asyncNote[0] == "caller-a"
    check $asyncNote[1] == "caller-b"
    ledgerDestroy(shared)
    shared = nil

  test "[IMPL-DECISION G336] an inline nested entry restores the outer handler's caller":
    shared = openLedger()
    probeHook = inlineEntry
    activeContext = addr ctxB
    let (code, r) = probe(shared, 8, 0)
    check code == ecOk
    check r.note == "caller-c|caller-b"
    ledgerDestroy(shared)
    shared = nil

  test "[IMPL-DECISION G336] P4: a plain handler re-enters an async handler inline while another async task resumes and reads its caller":
    shared = openLedger()
    probeHook = inlineEntry
    ticket.store(0)
    var t: Thread[int]
    createThread(t, asyncCaller, 0) # sleeps 60 ms, then reads caller-a
    sleep(15)
    activeContext = addr ctxB
    # The inline async entry sleeps 150 ms on the module thread: the task above
    # resumes inside that nested poll.
    let (code, r) = probe(shared, 8, 150)
    let mainDone = ticket.fetchAdd(1)
    joinThread(t)
    check code == ecOk
    check r.note == "caller-c|caller-b"
    check $asyncNote[0] == "caller-a"
    check asyncDone.load < mainDone # it returned while the plain handler was inside
    ledgerDestroy(shared)
    shared = nil

suite "confined kit: publication (DECISIONS G337)":
  setup:
    resetRuntime()

  test "[IMPL-DECISION G337] publish is queued and delivered in order on the publisher thread, not the module's or the caller's":
    let ctx = openLedger()
    var module: uint64
    for i in 1 .. 5:
      let (code, r) = post(ctx, "k" & $i)
      check code == ecOk
      module = r.thread
    let (_, w) = wait(ctx, 3, value = 1) # publishAsync: after the five
    check w.note == "ok"
    check seenKeys("plain") == @["k1", "k2", "k3", "k4", "k5", "async"]
    for t in seenThreads("k1") & seenThreads("async"):
      check t != module and t != here()
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G337] P3: publishScoped from a plain handler runs on the entry thread while a subscriber re-enters from it":
    let ctx = openLedger()
    reenterModule.store(ctx)
    activeContext = addr ctxB
    let (code, r) = probe(ctx, 2, 4)
    check code == ecOk
    check r.note == "ok"
    check seenThreads("scoped") == @[here()]
    check reentries.load == 1
    check reentryFailures.load == 0
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G337] [IFC-0281] [IFC-0282] a subscriber re-enters during each publication path, plain and async":
    let ctx = openLedger()
    reenterModule.store(ctx)
    activeContext = addr ctxB
    check post(ctx, "queued")[0] == ecOk # publish: the publisher thread
    check wait(ctx, 3)[1].note == "ok" # publishAsync: the publisher thread
    check wait(ctx, 7)[1].note == "ok"
      # an async handler's publishScoped: the publisher thread
    check probe(ctx, 2)[1].note == "ok" # a plain handler's publishScoped: this thread
    check reentries.load == 4
    check reentryFailures.load == 0
    check seenKeys("plain") == @["queued", "async"]
    check seenKeys("scoped") == @["scoped-async", "scoped"]
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G337] an entry with queued scoped events returns only after they were delivered":
    let ctx = openLedger()
    activeContext = addr ctxA
    publishDelay.store(30)
    let (code, w) = wait(ctx, 2, value = 1)
    check code == ecOk and w.note == "sent"
    check seenKeys("scoped") == @["unawaited"]
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G337] ABI 3: the callback's refusals show in publishRefusals, lastPublishRefusal and publishAsync's result":
    let ctx = openLedger()
    check probe(ctx, 9)[1].note == "0"
    callbackCode.store(int32(ord(ecNotAuthorised)))
    check post(ctx, "refused")[0] == ecOk # queued: OK is not acceptance
    check wait(ctx, 3)[1].note == $ecNotAuthorised
    check probe(ctx, 9)[1].note == "2 " & $ord(ecNotAuthorised) & " ledger.posted_event"
    callbackCode.store(0)
    check wait(ctx, 3)[1].note == "ok"
    check probe(ctx, 9)[1].note.startsWith("2 ")
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G337] a full queue: publish answers the kit's NOT_READY, publishAsync waits for room":
    shared = openLedger()
    holdPublish.store(true)
    check post(shared, "first")[0] == ecOk
    while not holding.load:
      sleep(1)
    # The callback holds `first`; the queue takes 64 more.
    let (_, flood) = probe(shared, 5, 100)
    check flood.note == "36"
    check probe(shared, 9)[1].note == "0" # the kit's refusals are not the callback's
    waitedRoom.store(false)
    var t: Thread[int]
    createThread(t, roomCaller, 0)
    sleep(30)
    check not waitedRoom.load
    holdPublish.store(false)
    joinThread(t)
    check waitedRoom.load
    check $roomNote == "ok"
    check seenCount("flood") == 64
    check seenCount("async") == 1
    ledgerDestroy(shared)
    shared = nil

  test "[IMPL-DECISION G337] destroy delivers the queued events before it returns, never after":
    let ctx = openLedger()
    publishDelay.store(2)
    let (_, flood) = probe(ctx, 5, 30)
    check flood.note == "0"
    check seenCount("flood") < 30
    let before = destroyed.load
    ledgerDestroy(ctx)
    check destroyed.load == before + 1
    check seenCount("flood") == 30
    sleep(20)
    check seenCount("flood") == 30

suite "confined kit: the module thread's dispatcher (DECISIONS G438)":
  setup:
    resetRuntime()

  test "[IMPL-DECISION G438] the dispatcher is made before the kit registers anything: it held only chronos's own descriptor":
    # What teardown leaves out of its count is what the dispatcher held when it
    # was made: none on 4.4.1, the wake-up descriptor alone on chronos's main
    # line. The kit's signal, registered by `arm`, is never among them.
    let ctx = openLedger()
    let line = probe(ctx, 27)[1].note
    check probe(ctx, 29)[1].note == (if line == "main line": "1" else: "0")
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G438] the kit's own signal that chronos could not close: one line saying so, its descriptor out of the count; the strict build goes on":
    when not defined(posix):
      skip()
    else:
      # `failSignalClose` leaves what chronos leaves when it cannot unregister:
      # the first descriptor open and registered. Counted, it would abort here.
      let ctx = openLedger()
      failSignalClose = true
      let output = capturingStderr(
        proc() =
          ledgerDestroy(ctx)
      )
      checkpoint output
      check (
        "logos module kit (confined): ledger_module: the kit's own signal could " &
        "not be closed (a test's failed unregister)"
      ) in output
      check "destroy left" notin output
      let fd = failedSignalFd
      failedSignalFd = -1
      check fd >= 0
      check fcntl(fd, F_GETFD) != -1 # open, as chronos leaves it
      discard close(fd)

  test "[IMPL-DECISION G438] an init that fails before the module thread starts makes no chronos dispatcher on the calling thread":
    when not defined(posix):
      skip()
    else:
      # chronos's close of the signal would make one there, with a descriptor.
      for step in 1 .. 3:
        var t: Thread[int]
        createThread(t, failingInit, step)
        joinThread(t)
        let f = initFailures[step - 1]
        checkpoint initFailureMessages[step - 1]
        check f.code == ord(ecModule)
        check f.named
        check f.noContext
        check f.after == f.before

suite "confined kit: lifecycle and foreign threads (DECISIONS G335)":
  setup:
    resetRuntime()

  test "[IMPL-DECISION G335] callbacks posted from C threads the Nim runtime never saw run on the module thread":
    let ctx = openLedger()
    posts.store(0)
    postThreads.store(0)
    let (code, r) = probe(ctx, 7, 4)
    check code == ecOk and r.note == "posted"
    discard probe(ctx, 1) # queued after the 40 callbacks
    check posts.load == 40
    check postThreads.load == 0
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G335] a failed init joins its threads and leaves no context":
    var inp = ledgerInput(stateDir = "/refuse")
    var ctx: ptr LogosModuleContext
    let r = ledgerInit(addr inp, addr ctx)
    check r.code == CErrorCode(ord(ecModule))
    check ctx == nil

  test "[IMPL-DECISION G335] 100 create and destroy cycles and 20 failed inits keep the open-descriptor count":
    when defined(windows):
      skip()
    else:
      block warm:
        let ctx = openLedger()
        discard post(ctx, "warm")
        ledgerDestroy(ctx)
      let fds = openDescriptors()
      for i in 0 ..< 100:
        let ctx = openLedger()
        discard post(ctx, "cycle")
        discard wait(ctx, 1, millis = 0)
        ledgerDestroy(ctx)
      for i in 0 ..< 20:
        var inp = ledgerInput(stateDir = "/refuse")
        var ctx: ptr LogosModuleContext
        discard ledgerInit(addr inp, addr ctx)
      check openDescriptors() == fds

suite "confined kit: consumer helpers on the module thread (DECISIONS G339)":
  setup:
    resetRuntime()
    resetFake()

  test "[IMPL-DECISION G339] [IFC-0516] [IFC-0518] [IFC-0671] [IFC-0717] [IFC-0736] handlers, end reports and completions run on the module thread, never in the delivery; the handle is released once and not used after":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed" # the generated typed subscribe
    deliver(1)
    deliver(2)
    deliver(3)
    check ctx.report.startsWith("seen=1,2,3 ") # each delivery decoded to its event
    endSubscription(ecModule)
    check " end=MODULE_ERROR " in ctx.report
    check probe(ctx, 11)[1].note == "ok" # after the binding ended it (l.1482)
    check probe(ctx, 13, 4)[1].note == "submitted"
    check fakePrepares.load == 1
    check fakeNullOnEntry.load == 1 # its output call was null on entry
    completeFake("ch4")
    check ownerReleases.load == 1
    check ownerReleaseThread.load == here() # cleared where it was delivered (l.2052)
    check " done=ok:ch4 " in ctx.report
    endRoute(ecNotReady)
    check " route=NOT_READY " in ctx.report
    check probe(ctx, 15)[1].note == "ok"
    check probe(ctx, 12)[1].note == "ok"
    check fakeReleased.load
    check fakeReleases.load == 1
    # The module's next call has no handle: refused before any route operation.
    check probe(ctx, 13, 5)[1].note == $ecInvalidParams
    check fakePrepares.load == 1
    check ctx.report.endsWith(" off=0")
    ledgerDestroy(ctx)
    check fakeReleases.load == 1
    check fakeLateOps.load == 0

  test "[IMPL-DECISION G339] P1: a delivery that finds the bound reached ends its subscription from inside the delivery; the queued events come first, then onEnd(MODULE_ERROR)":
    shared = openLedger()
    check probe(shared, 10)[1].note == "subscribed"
    check probe(shared, 16, 2)[1].note == "bound"
    probeHook = holdHook
    gate.store(true)
    gateEntered.store(false)
    var t: Thread[int]
    createThread(t, holder, 0)
    while not gateEntered.load:
      sleep(1)
    deliver(1)
    deliver(2) # the bound: two queued
    deliver(3) # ends the subscription
    deliver(4) # nothing to deliver to
    check fakeUnsubscribes.load == 1
    check fakeUnsubscribesInside.load == 1
    gate.store(false)
    joinThread(t)
    let r = shared.report
    check r.startsWith("seen=1,2 end=MODULE_ERROR ")
    check probe(shared, 11)[1].note == "ok" # already unsubscribed from the binding
    check fakeUnsubscribes.load == 1
    check r.endsWith(" off=0")
    ledgerDestroy(shared)
    shared = nil

  test "[IMPL-DECISION G339] a delivery on the module thread itself is queued, never run inline; an unsubscription drops what is queued for it":
    shared = openLedger()
    check probe(shared, 10)[1].note == "subscribed"
    deliver(1)
    probeHook = deliverInsideHook
    check probe(shared, 8)[1].note.startsWith("0 ok|")
    check shared.report.startsWith("seen=1 ")
    deliver(7) # unsubscribed: nothing reaches the handler
    check shared.report.startsWith("seen=1 ")
    ledgerDestroy(shared)
    shared = nil

  test "[IMPL-DECISION G339] the handler rule on the module thread: an operation on the handler's own handle is NOT_READY, its own unsubscription succeeds":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    deliver(98)
    check " rule=NOT_READY " in ctx.report
    deliver(99)
    check " rule=ok " in ctx.report
    check fakeUnsubscribes.load == 1
    deliver(7)
    check ctx.report.startsWith("seen= ")
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G339] [IFC-0724] [IFC-0735] [IFC-0736] a completion inside submit is queued, not run inline, and reaches its handler with its user state; a call released before it ran never completes, its owner still cleared":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    fakeCompleteInSubmit.store(true)
    check probe(ctx, 17, 2)[1].note == "none ok"
    check fakeReadyAtSubmit.load == 1 # its callback and user state, before submit
    check ownerReleases.load == 1 # the result discarded, its owner cleared
    check fakeCallReleases.load == 1
    check " done= " in ctx.report
    check fakeSubmits.load == 1 and fakeCancels.load == 0
    check fakeLateCallUses.load == 0 # neither submitted nor cancelled once released
    # Not released: the completion made inside submit reaches onDone, whose
    # user state is the instance.
    check probe(ctx, 13, 3)[1].note == "submitted"
    check fakeReadyAtSubmit.load == 2
    check " done=ok:inline " in ctx.report
    check ownerReleases.load == 2
    check probe(ctx, 15)[1].note == "ok"
    check fakeCallReleases.load == 2
    check ctx.report.endsWith(" off=0")
    ledgerDestroy(ctx)
    check fakeSubmits.load == 2 and fakeCancels.load == 0
    check fakeLateCallUses.load == 0

  test "[IMPL-DECISION G339] [IFC-0516] [IFC-0518] destroy releases a handle with an outstanding call and a live subscription, once, and uses neither after":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    check probe(ctx, 13, 1)[1].note == "submitted"
    deliver(1)
    ledgerDestroy(ctx)
    check fakeReleased.load
    check fakeReleases.load == 1
    check fakeLateOps.load == 0
    check fakeCallReleases.load == 1
    check fakeLateCallUses.load == 0

suite "confined kit: the deferred provider (DECISIONS G338)":
  setup:
    resetRuntime()
    resetFake()

  test "[IFC-0743] [IFC-0746] the getter is context-free and returns one valid descriptor, the same from every thread":
    let api = ledgerAsyncApi()
    check checkAsyncProviderApi(api).isOk
    check api.abiVersion == AsyncProviderAbiVersion
    check api.structSize == csize_t(sizeof(LogosAsyncProviderApi))
    check not api.submit.isNil
    check not api.requestCancel.isNil
    var t: Thread[int]
    createThread(t, apiReader, 0)
    joinThread(t)
    check apiSeen.load == cast[pointer](api)
    let ctx = openLedger()
    check ledgerAsyncApi() == api
    ledgerDestroy(ctx)
    check ledgerAsyncApi() == api

  test "[IFC-0748] [IFC-0749] [IFC-0751] a submitted invocation answers what _MODULE_dispatch answers, with its own context":
    let ctx = openLedger()
    activeContext = addr ctxA
    let cases = [
      ("probe", request(LedgerProbeRequest(channel: 1, value: 3))),
      ("probe", request(LedgerProbeRequest(channel: 3))),
      ("post", request(LedgerPostRequest(key: "k", amount: 0))),
      ("wait", request(LedgerWaitRequest(channel: 1, millis: 2, value: 9))),
      ("wait", request(LedgerWaitRequest(channel: 5))),
      ("seal", request(LedgerSealRequest(secret: @[1'u8, 2, 3]))),
      ("nosuch", request(LedgerProbeRequest(channel: 1))),
      ("probe", diag("{\"channel\": \"one\", \"value\": 0}")),
    ]
    for i, (bare, params) in cases:
      let d = call(ledgerDispatch, ledgerFree, ctx, bare, params)
      # What `current` says on the submitting thread is not the invocation's.
      activeContext = addr ctxB
      let fi = deferred(ctx, i, bare, params, id = "caller-a")
      activeContext = addr ctxA
      checkpoint(bare & " " & $i)
      check same(fi.status, d.status)
      check fi.responseOf == d.response
      check fi.exactlyOnce
      check fi.unchanged
      clearFake(fi)
    check fakes[0].completeThread == probe(ctx, 1)[1].thread
    ledgerDestroy(ctx)

  test "[IFC-0750] [IFC-0766] submit and request_cancel return while the module thread is busy; a job cancelled before it ran answers CANCELLED without its handler":
    shared = openLedger()
    probeHook = holdHook
    gate.store(true)
    gateEntered.store(false)
    var t: Thread[int]
    createThread(t, holder, 0)
    while not gateEntered.load:
      sleep(1)
    let fi =
      prepareFake(0, "wait", request(LedgerWaitRequest(channel: 9, millis: 20_000)))
    let started = epochTime()
    submit(shared, fi)
    cancel(shared, fi)
    check epochTime() - started < 1.0
    check fi.completes.load == 0
    gate.store(false)
    joinThread(t)
    check fi.settledIn()
    check epochTime() - started < 10.0
    check fi.status.error.code == ecCancelled
    check fi.message == "cancelled before its handler ran"
    check fi.exactlyOnce
    clearFake(fi)
    ledgerDestroy(shared)
    shared = nil

  test "[IMPL-DECISION G338] [IFC-0753] a cancellation reaches an async handler's future while it awaits; the handler decides the outcome":
    let ctx = openLedger()
    let a =
      prepareFake(0, "wait", request(LedgerWaitRequest(channel: 9, millis: 20_000)))
    let b =
      prepareFake(1, "wait", request(LedgerWaitRequest(channel: 1, millis: 20_000)))
    let started = epochTime()
    submit(ctx, a)
    submit(ctx, b)
    discard probe(ctx, 1) # both handlers are asleep once this returns
    check a.completes.load == 0
    check b.completes.load == 0
    cancel(ctx, a)
    cancel(ctx, b)
    check a.settledIn()
    check b.settledIn()
    check epochTime() - started < 10.0
    # wait 9 answers CANCELLED; wait 1 swallows the cancellation and answers.
    check a.status.error.code == ecCancelled
    check a.message == "wait 9 was cancelled"
    check b.status.isOk
    check LedgerWaitResponse.decode(b.responseOf).get.note == "deferred"
    check a.exactlyOnce
    check b.exactlyOnce
    clearFake(a)
    clearFake(b)
    # A context already cancelled when the job starts: CANCELLED, no handler.
    let c = prepareFake(2, "probe", request(LedgerProbeRequest(channel: 4)))
    c.cancelled.store(true)
    submit(ctx, c)
    check c.settledIn()
    check c.status.error.code == ecCancelled
    check c.message == "cancelled before its handler ran"
    clearFake(c)
    ledgerDestroy(ctx)

  test "[IFC-0762] [IFC-0763] [IFC-0753] request_cancel after the release returns harmlessly; hooks race 64 completions from 4 threads":
    let ctx = openLedger()
    let done = deferred(ctx, 70, "probe", request(LedgerProbeRequest(channel: 1)))
    ledgerAsyncApi().requestCancel(ctx, addr done.inv)
    discard probe(ctx, 1)
    check done.exactlyOnce
    clearFake(done)
    shared = ctx
    workerFailures.store(0)
    for k in 0 ..< 64:
      discard prepareFake(
        k, "wait", request(LedgerWaitRequest(channel: 9, millis: uint32(k mod 4)))
      )
    var subs, cans: array[4, Thread[int]]
    for t in 0 ..< 4:
      createThread(subs[t], submitter, t)
      createThread(cans[t], canceller, t)
    for t in 0 ..< 4:
      joinThread(subs[t])
      joinThread(cans[t])
    var ok, cancelledCount = 0
    for k in 0 ..< 64:
      let fi = addr fakes[k]
      check fi.settledIn()
      check fi.exactlyOnce
      let st = fi.status
      if st.isOk:
        inc ok
      else:
        check st.error.code == ecCancelled
        check k mod 2 == 0
        inc cancelledCount
      clearFake(fi)
    check ok + cancelledCount == 64
    check ok >= 32
    check workerFailures.load == 0
    shared = nil
    ledgerDestroy(ctx)

  test "[IFC-0753] [IFC-0754] the completion's regions stay readable and unchanged until its owner is cleared, on another thread":
    let ctx = openLedger()
    let good =
      deferred(ctx, 0, "wait", request(LedgerWaitRequest(channel: 1, millis: 1)))
    let bad = deferred(ctx, 1, "probe", request(LedgerProbeRequest(channel: 3)))
    check good.status.isOk
    check bad.status.error.code == ecModule
    check bad.message == "probe 3 fails"
    check not good.owner.release.isNil
    check not bad.owner.release.isNil
    for i in 0 ..< 20:
      check post(ctx, "churn")[0] == ecOk
      discard wait(ctx, 1, millis = 1)
    check good.unchanged
    check bad.unchanged
    var t: array[2, Thread[ptr FakeInvocation]]
    createThread(t[0], ownerClearer, good)
    createThread(t[1], ownerClearer, bad)
    joinThread(t[0])
    joinThread(t[1])
    ledgerDestroy(ctx)

  test "[IFC-0752] [IFC-0779] after its release the invocation is not used: its Invocation refuses, its context and borrowed request are not touched":
    let ctx = openLedger()
    let fi = deferred(ctx, 0, "wait", request(LedgerWaitRequest(channel: 4)))
    check LedgerWaitResponse.decode(fi.responseOf).get.note == "kept"
    for b in fi.params.mitems:
      b = 0xFF
    for c in fi.methodName.mitems:
      c = 'x'
    fi.context.vtable = nil
    activeContext = addr ctxA
    check probe(ctx, 6)[1].note == $ecNotReady
    discard wait(ctx, 1, millis = 1)
    check fi.exactlyOnce
    clearFake(fi)
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G338] scoped publications of a submitted invocation, plain and async, are answered before its completion, while a subscriber re-enters":
    let ctx = openLedger()
    publishDelay.store(20)
    reenterModule.store(ctx)
    let p = deferred(ctx, 0, "probe", request(LedgerProbeRequest(channel: 2, value: 5)))
    check p.status.isOk
    check LedgerProbeResponse.decode(p.responseOf).get.note == "ok"
    check p.atCompletion == 1
    let w = deferred(ctx, 1, "wait", request(LedgerWaitRequest(channel: 2, value: 6)))
    check w.status.isOk
    check w.atCompletion == 2
    let w7 = deferred(ctx, 2, "wait", request(LedgerWaitRequest(channel: 7, value: 7)))
    check LedgerWaitResponse.decode(w7.responseOf).get.note == "ok"
    check w7.atCompletion == 3
    check seenKeys("scoped") == @["scoped", "unawaited", "scoped-async"]
    let module = LedgerProbeResponse.decode(p.responseOf).get.thread
    for th in seenThreads("scoped"):
      check th != module
    check reentries.load == 3
    check reentryFailures.load == 0
    for fi in [p, w, w7]:
      check fi.exactlyOnce
      clearFake(fi)
    reenterModule.store(nil)
    ledgerDestroy(ctx)

  test "[IFC-0769] [IMPL-DECISION G338] destroy with a submitted invocation outstanding completes it NOT_READY once and releases it":
    let ctx = openLedger()
    let fi =
      prepareFake(0, "wait", request(LedgerWaitRequest(channel: 1, millis: 20_000)))
    submit(ctx, fi)
    discard probe(ctx, 1) # its handler is asleep
    let freedBefore = freed.load
    let started = epochTime()
    ledgerDestroy(ctx)
    check epochTime() - started < 10.0
    check fi.exactlyOnce
    check fi.status.error.code == ecNotReady
    when defined(gcOrc):
      # Destroy cancelled the handler and it unwound: the instance and the
      # handler's task are freed once the module thread ends.
      check freed.load == freedBefore + 1
    clearFake(fi)

  test "[IFC-0769] [IMPL-DECISION G338] destroy abandons a handler that ignores its cancellation once the bound passes: NOT_READY once, its frames kept":
    when defined(asan):
      # The abandoned task is the residue G338 keeps on purpose (INTERFACE
      # l.2116-2117); LeakSanitizer would report it. Every other build runs it.
      skip()
    else:
      let ctx = openLedger()
      let fi =
        prepareFake(0, "wait", request(LedgerWaitRequest(channel: 11, millis: 20_000)))
      submit(ctx, fi)
      discard probe(ctx, 1) # its handler is asleep
      let freedBefore = freed.load
      let started = epochTime()
      ledgerDestroy(ctx)
      let took = epochTime() - started
      check took >= 1.5 and took < 10.0
      check fi.exactlyOnce
      check fi.status.error.code == ecNotReady
      when defined(gcOrc):
        # The abandoned frames still hold the instance.
        check freed.load == freedBefore
      clearFake(fi)

  test "[IMPL-DECISION G338] invokeAsync through a wrapped handle: completion, deadline, and the awaiting handler's cancellation":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    let a = prepareFake(
      0, "wait", request(LedgerWaitRequest(channel: 10, millis: 250, value: 4))
    )
    submit(ctx, a)
    discard probe(ctx, 1) # the handler awaits its call, prepared and submitted
    check fakeTimeout.load == 250
    check a.completes.load == 0
    completeFake("ch4")
    check a.settledIn()
    check LedgerWaitResponse.decode(a.responseOf).get.note == "ok:ch4"
    check ownerReleases.load == 1
    discard probe(ctx, 1)
    check fakeCallReleases.load == 1 # released once its completion returned
    let b = prepareFake(1, "wait", request(LedgerWaitRequest(channel: 10, value: 5)))
    submit(ctx, b)
    discard probe(ctx, 1)
    check fakeTimeout.load == 0
    fakeCancelCompletes.store(true)
    cancel(ctx, b)
    check b.settledIn()
    check fakeCancels.load == 1
    check LedgerWaitResponse.decode(b.responseOf).get.note == $ecCancelled
    discard probe(ctx, 1)
    check fakeCallReleases.load == 2
    for fi in [a, b]:
      check fi.exactlyOnce
      clearFake(fi)
    check ctx.report.endsWith(" off=0")
    ledgerDestroy(ctx)

  test "[IMPL-DECISION G338] invokeAsync off a module thread, or through a handle no confined kit wrapped, answers NOT_READY at once":
    let h =
      wrapRoute(LogosRouteHandle(vtable: addr fakeVtable, state: addr fakeState)).get
    let f = h.invokeAsync(MeterReadRequest(channel: 1))
    check f.finished()
    check f.value.isErr
    check f.value.error.code == ecNotReady
    check fakeTimeout.load == 0
    discard h.release()

suite "confined kit: what runs while destroyModule runs (DECISIONS G437)":
  setup:
    resetRuntime()
    resetFake()
    resetDestroy()

  test "[IMPL-DECISION G437] destroyModule awaits a callback a foreign C thread posts 50 ms in":
    let ctx = openLedger()
    let freedBefore = freed.load
    destroyMode.store(1)
    let started = epochTime()
    ledgerDestroy(ctx)
    # Under the order before G437 the callback was dropped, and only the
    # fixture's 5 s bound ended the wait: the 1 s bound catches that.
    check epochTime() - started < 1.0
    check destroyNote() == "woke=true"
    check posts.load == 1
    when defined(gcOrc):
      check freed.load == freedBefore + 1

  test "[IMPL-DECISION G437] destroyModule awaits invokeAsync; the completion arrives 100 ms into destroyModule":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    destroyMode.store(2)
    var t: Thread[(int, int)]
    createThread(t, completeInDestroy, (100, 1))
    let started = epochTime()
    ledgerDestroy(ctx)
    joinThread(t)
    check epochTime() - started < 1.0
    check destroyNote() == "ok:destroy"
    check ownerReleases.load == 1
    check fakeCallReleases.load == 1
    check fakeReleased.load

  test "[IMPL-DECISION G437] destroyModule awaits publishAsync: ok, and the publish callback saw the event":
    let ctx = openLedger()
    destroyMode.store(3)
    ledgerDestroy(ctx)
    check destroyNote() == "ok"
    check seenCount("destroy") == 1

  test "[IMPL-DECISION G437] posts queued by a destroyModule that returns without yielding never run":
    let ctx = openLedger()
    let freedBefore = freed.load
    destroyMode.store(4)
    ledgerDestroy(ctx)
    check destroyNote() == "posted"
    check posts.load == 0
    check postThreads.load == 0
    when defined(gcOrc):
      check freed.load == freedBefore + 1

  test "[IMPL-DECISION G437] events are dropped from the start of destroy, while destroyModule awaits":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    deliver(1)
    check ctx.report.startsWith("seen=1 ")
    destroyMode.store(5)
    deliveredInDestroy.store(0)
    var t: Thread[int]
    createThread(t, deliverInDestroy, 0)
    ledgerDestroy(ctx)
    joinThread(t)
    check deliveredInDestroy.load == 2 # both reached the kit's subscription
    check destroyNote() == "woke=true seen=1"

  test "[IMPL-DECISION G437] [IFC-0769] a handler that ignored its cancellation past the unwinding's bound finishes during destroyModule: NOT_READY once":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    let fi = prepareFake(0, "wait", request(LedgerWaitRequest(channel: 12, value: 3)))
    submit(ctx, fi)
    discard probe(ctx, 1) # its handler awaits its call, prepared and submitted
    check fakePrepares.load == 1
    let freedBefore = freed.load
    destroyMode.store(6)
    var t: Thread[(int, int)]
    createThread(t, completeInDestroy, (500, 1))
    let started = epochTime()
    ledgerDestroy(ctx)
    joinThread(t)
    let took = epochTime() - started
    check took >= 1.5 and took < 10.0 # the unwinding's 2 s bound passed first
    check destroyNote() == "residual=1"
    check fakeCancels.load == 0 # `noCancel`: its call was never cancelled
    check fi.exactlyOnce
    check fi.status.error.code == ecNotReady
    when defined(gcOrc):
      check freed.load == freedBefore + 1 # its frames ended: nothing abandoned
    clearFake(fi)

  test "[IMPL-DECISION G437] a foreign stream that destroyModule stops and joins: no callback after it returned":
    let ctx = openLedger()
    let freedBefore = freed.load
    check probe(ctx, 24)[1].note == "streaming"
    check streamedAtLeast(20)
    ledgerDestroy(ctx)
    check lateCalls.load == 0
    when defined(gcOrc):
      check freed.load == freedBefore + 1

  test "[IMPL-DECISION G437] a foreign stream while destroyModule awaits a delayed post: callbacks run during it, none after it returned":
    let ctx = openLedger()
    let freedBefore = freed.load
    check probe(ctx, 24)[1].note == "streaming"
    check streamedAtLeast(20)
    destroyMode.store(7)
    ledgerDestroy(ctx)
    check destroyNote() == "woke=true"
    check streamedDuring.load > 0
    check lateCalls.load == 0
    when defined(gcOrc):
      check freed.load == freedBefore + 1

# The post gate (DECISIONS G440) ---------------------------------------------------------
#
# A post that comes after `_MODULE_destroy` returned breaks the module's duty
# (MODULE-KIT §3); these cases break it on purpose, and the gate must refuse it
# instead of reaching the freed context.

proc posterOf(ctx: ptr LogosModuleContext): pointer =
  ## The instance's poster value, from `probe` 28.
  cast[pointer](uint(parseBiggestUInt(probe(ctx, 28)[1].note)))

suite "confined kit: the post gate (DECISIONS G440)":
  setup:
    resetRuntime()
    resetFake()
    resetDestroy()
    refusedPoster.store(nil)

  test "[IMPL-DECISION G440] the packing: never null, a round trip, the last generation retires its slot":
    check packGate(0, 0) != nil
    for slot in [0, 1, GateMaxSlots - 1]:
      for gen in [0'u64, 1, GateMaxGen - 1, GateMaxGen]:
        let p = packGate(slot, gen)
        check p != nil
        check unpackGate(p).slot == slot and unpackGate(p).gen == gen
    # The largest value fills 64 bits exactly: no generation wraps into the slot.
    check cast[uint64](packGate(GateMaxSlots - 1, GateMaxGen)) == high(uint64)
    check unpackGate(nil).gen > GateMaxGen # null names no generation a slot is at
    check gateNext(0).gen == 1 and not gateNext(0).retired
    check gateNext(GateMaxGen - 1).gen == GateMaxGen and
      not gateNext(GateMaxGen - 1).retired
    check gateNext(GateMaxGen).gen == GateMaxGen + 1 and gateNext(GateMaxGen).retired

  test "[IMPL-DECISION G440] post and lcn_kit_post after _MODULE_destroy returned are refused; fn never runs":
    let ctx = openLedger()
    let p = posterOf(ctx)
    postFromNim(p)
    check postFromC(p)
    discard probe(ctx, 1) # queued after both callbacks
    check posts.load == 2
    check postThreads.load == 0
    let freedBefore = freed.load
    ledgerDestroy(ctx)
    when defined(gcOrc):
      check freed.load == freedBefore + 1 # the instance is gone
    postFromNim(p)
    check postFromC(p)
    check posts.load == 2

  test "[IMPL-DECISION G440] deliveries, end reports and a completion for handles destroyModule left unreleased are dropped through the gate":
    let ctx = openLedger()
    check probe(ctx, 10)[1].note == "subscribed"
    check probe(ctx, 13, 1)[1].note == "submitted"
    let freedBefore = freed.load
    destroyMode.store(8)
    ledgerDestroy(ctx)
    check destroyNote() == "left"
    when defined(gcOrc):
      check freed.load == freedBefore + 1 # its handlers' user value is gone
    check not fakeReleased.load # the module's duty, broken on purpose
    check fakeCallReleases.load == 0
    let h = leftRoute
    check pendingTasks(h) == 0
    let delivered = deliveries.load
    deliver(1)
    check deliveries.load == delivered + 1 # it reached the kit's subscription
    check pendingTasks(h) == 0 # its task was dropped, and its count went with it
    completeFake("late")
    check ownerReleases.load == 1
    endSubscription(ecModule)
    check pendingTasks(h) == 0
    endRoute(ecNotReady)
    check pendingTasks(h) == 0
    check lateCalls.load == 0 # no handler ran

  test "[IMPL-DECISION G440] a poster an initModule gave away before it failed is refused":
    var inp = ledgerInput(stateDir = "/refuse-poster")
    var ctx: ptr LogosModuleContext
    check ledgerInit(addr inp, addr ctx).code == CErrorCode(ord(ecModule))
    check ctx == nil
    let p = refusedPoster.load
    check p != nil
    postFromNim(p)
    check postFromC(p)
    check posts.load == 0

  test "[IMPL-DECISION G440] a slot reused by the next context refuses the old poster; the new poster works":
    let a = openLedger()
    let pa = posterOf(a)
    ledgerDestroy(a)
    let b = openLedger()
    let pb = posterOf(b)
    check unpackGate(pb).slot == unpackGate(pa).slot # the last slot freed goes first
    check unpackGate(pb).gen == unpackGate(pa).gen + 1
    postFromNim(pa)
    check postFromC(pa)
    discard probe(b, 1)
    check posts.load == 0
    postFromNim(pb)
    check postFromC(pb)
    discard probe(b, 1)
    check posts.load == 2
    check postThreads.load == 0
    ledgerDestroy(b)

  test "[IMPL-DECISION G440] a foreign stream posting through destroy and on into the slot's next context: each post served or refused, none run after the return (20 cycles)":
    var ctx = openLedger()
    for i in 0 ..< 20:
      check probe(ctx, 24)[1].note == "streaming"
      check streamedAtLeast(1 + i mod 5)
      destroyMode.store(9)
      ledgerDestroy(ctx)
      check destroyNote() == "streaming"
      # The next context most likely takes the same slot, a generation on,
      # while the stream still posts with the old value.
      ctx = openLedger()
      sleep(2)
      check stopLeftStream() > 0
      check lateCalls.load == 0
      resetDestroy()
    ledgerDestroy(ctx)
