## A thread-confined kit module built with the other memory manager (DECISIONS
## G342, G335-G337, G339; step N-1 sub-part 3; plan §3.6): the ledger fixture
## (`sdk/src/logos_sdk/testing/fixtures/ledger_impl.nim`, `lcn-gen kit
## --confined`) as a library built with `otherMm` (refc beside this orc build,
## orc beside a refc one), realized by this process's Runtime
## (`direct_dynamic`) and by a Module Host process (`hosted_dynamic`).
##
## The library's own runtime runs each instance on its module thread, so its
## handlers keep GC'd state in the instance whatever thread the Runtime calls
## from. The cases call it from 16 threads at once, subscribe to its event and
## re-enter it from the delivering thread, take its publications from a
## handler's scope, a timer on the module thread and foreign C threads' posts,
## and run two instances at once, stops and re-creations. As a consumer it
## opens a route to the meter through its Runtime Control binding (`kit/routes`)
## and its typed handlers run on its module thread: deliveries, a subscription
## its full queue ended, one the authority ended, a completion and a route end.
## Its kit exports `_MODULE_async_api` (G338): the Runtime's prepared calls and
## the Module Host's transported calls take that deferred surface, and a
## cancellation or a deadline reaches its `async` handler.
##
## Under refc the cases skip: a refc Runtime refuses every route to a contract
## that marks a payload (DECISIONS G277), as the ledger's does, so they pair an
## orc Runtime and Module Host with a refc module, the node's own pairing;
## `sdk/tests/test_kit_dylib.nim` loads the ledger built with the other manager
## in both builds. `run.mixed` in `tests/test_hosted_routes.nim` stays the
## check of the plain kit's pairing. Waits that only bound a test scale with
## `Slow`.

when defined(posix):
  import std/[atomics, monotimes, os, strutils, times, typedthreads]
  import std/posix except Time
  import unittest2
  import ../src/logos_core/runtime/engine
  import logos_sdk/abi/types
  import logos_sdk/base/perthread
  import logos_sdk/cbor
  import logos_sdk/commitment
  import logos_sdk/crypto/blake3
  import logos_sdk/pins
  import logos_sdk/iface/[accept, outcome, surface]
  import logos_sdk/codegen/common_types
  import logos_sdk/testing/[kitbuild, kitruntime]
  import ./support/[fakeca, modulehostbuild, shortdir]
  from ./support/trnowner import fastConfig, Ms
  import logos_sdk/testing/fixtures/meter_impl
  import
    logos_sdk/testing/generated/
      [ledger_module_calls, meter_module_calls, meter_module_types]

  let
    repo = currentSourcePath().parentDir.parentDir
    work = repo / "build" / "kit-mixed" / kitVariant
  removeDir(work)
  createDir(work)

  include ./support/routefixture

  let shortBase = makeShortBase("lcnkm", "/e999/12345678/logos_ledger_module.sock")

  const
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    Answer = 60 * Slow ## seconds: a bound on a wait for what comes
    PosterThreads = 16
    PostsPerThread = 20
    # [DECISIONS G342] A refc library is built without the sanitizer
    # (`kitbuild`); MemorySanitizer takes what uninstrumented code writes for
    # uninitialized (DECISIONS I77), so its run skips these cases.
    mixedUninstrumented = defined(msan) and otherMm == "refc"

  template instrumentedOnly() =
    if mixedUninstrumented:
      skip()
      break
    # [DECISIONS G277] A refc Runtime or Module Host refuses every route to a
    # contract that marks a payload, as the ledger's `seal` does, so under refc
    # nothing reaches it: these cases pair an orc Runtime and host with a refc
    # module, the node's own pairing. `sdk/tests/test_kit_dylib.nim` loads the
    # ledger built with the other manager in both builds.
    if kitMm == "refc":
      skip()
      break

  let
    hostProgram = moduleHostProgram()
    # [DECISIONS G340, G341] Its main module imports chronos before the kit,
    # and it is linked with the kit's export list, as a port builds it.
    ledgerLib =
      buildKitLibrary("ledger_lib.nim", "kmledgerx", otherMm, exports = "ledger_module")
    ledgerDigest = block:
      var h: Blake3Hasher
      h.init()
      let bytes = readFile(ledgerLib)
      h.update(bytes.toOpenArrayByte(0, bytes.high))
      h.finish()
    ledgerSet = acceptContractSet(
      readFile(repo / "sdk/src/logos_sdk/testing/fixtures/ledger_module.cddl")
    ).tryGet
    ledgerRoot = ledgerSet.primary.root
    ledgerSchema = encodeCbor(schemaResponse(ledgerSet, ledgerRoot).tryGet)

  # Set-up -------------------------------------------------------------------------------

  proc roomy(): auto =
    ## `fastConfig` whose Hello and admission deadlines are `Answer`: no case
    ## here is about them.
    var c = fastConfig()
    c.helloTimeout = int64(1000 * Answer) * Ms
    c.admissionTimeout = int64(1000 * Answer) * Ms
    c

  proc hosted(): EngineConfig =
    ## `config` with a state root, the Module Host program and a short
    ## endpoint directory.
    result = config()
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    result.endpointDir = shortBase / ("e" & $engines)
    result.transport = Opt.some(roomy())
    result.shutdownGrace = initDuration(seconds = 10 * Slow)

  proc underAuthority(): EngineConfig =
    ## `hosted` with the fake Capability Authority bound (instance "ca").
    resetFake()
    result = hosted()
    result.statics.add(fakeCaRegistration())
    result.authority = Opt.some(
      AuthorityPolicy(instance: "ca", evaluationDeadline: initDuration(seconds = 60))
    )

  proc startAuthority(e: Engine) =
    discard e.create(fakeCaRecord(), "ca").tryGet
    doAssert e.start("ca").tryGet.state == msReady

  proc stateOf(cfg: EngineConfig, state: string): string =
    result = cfg.stateRoot.get / state
    createDir(result)

  proc noHostLeft(): bool =
    waitUntil(
      proc(): bool =
        hostPids(hostProgram).len == 0
    )

  proc ledgerRecord(hosted: bool, state: string): ModuleRecord =
    ModuleRecord(
      module: "ledger_module",
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: "process" else: ""),
      artifact: ArtifactRecord(
        id: "ledgerx", localPath: ledgerLib, hash: ledgerDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(ledgerRoot),
      stateAssignment: Opt.some(state),
    )

  func hexOf(b: openArray[byte]): string =
    for x in b:
      result.add(toHex(x, 2))

  proc ledgerHandle(
      rc: ptr LogosRuntimeControlBinding, key: string, v: InstanceView
  ): LogosRouteHandle =
    ## A route of its own to the instance `v`, materialized once: a
    ## transported route's ticket opens one connection (G258).
    let made =
      rc.establish(key, ledgerRoot, provider = Opt.some(providerAddress(v.providerId)))
    check made.code == ecOk
    if made.code != ecOk:
      return LogosRouteHandle()
    let (code, h) =
      rc.materialize(made.routesOf.routes[0].route, ledgerRoot, ledgerSchema)
    check code == ecOk
    h

  proc drop(h: var LogosRouteHandle) =
    ## `release`, for a handle that may not have been materialized (a failed
    ## check already reported it).
    if h.vtable != nil:
      h.release()
      h = LogosRouteHandle()

  proc probe(h: var LogosRouteHandle, channel: uint32, value = 0'u64): string =
    if h.vtable == nil:
      return "no handle"
    let r = invoke(addr h, LedgerProbeRequest(channel: channel, value: value))
    if r.isOk:
      r.get.note
    else:
      "error " & $r.error.code

  proc post(
      h: var LogosRouteHandle, key: string
  ): Result[LedgerPostResponse, InvocationFailure] =
    invoke(addr h, LedgerPostRequest(key: key, amount: 1))

  proc probeUntil(
      h: var LogosRouteHandle, channel: uint32, part: string, seconds = Answer
  ): string =
    ## The note of `probe channel` once it holds `part`, or the last one.
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    while true:
      result = h.probe(channel)
      if part in result or getMonoTime() > deadline:
        return
      sleep(5)

  proc refused(h: var LogosRouteHandle): int =
    ## The instance's `post` publications its kit refused, its queue full.
    let words = h.probe(22).split(' ')
    if words.len == 3:
      try:
        parseInt(words[2])
      except ValueError:
        -1
    else:
      -1

  # The test's subscriber to `ledger.posted_event` ---------------------------------------
  #
  # Plain data in globals: handlers run on the Runtime's threads (refc).

  type Posted = object
    count: Atomic[int] ## deliveries handled
    bad: Atomic[int] ## deliveries that did not decode
    scoped, timer: Atomic[int] ## the last `total` of the keys `scoped` and `timer`
    reentered: Atomic[int] ## re-entries answered with the expected caller
    reenter: LogosRouteHandle ## used by the handler only
    caller: array[64, char]
    callerLen: int

  var posted: Posted

  proc resetPosted(caller: string) =
    posted.count.store(0)
    posted.bad.store(0)
    posted.scoped.store(0)
    posted.timer.store(0)
    posted.reentered.store(0)
    posted.reenter = LogosRouteHandle()
    posted.callerLen = min(caller.len, posted.caller.len)
    for i in 0 ..< posted.callerLen:
      posted.caller[i] = caller[i]

  proc callerIs(note: string): bool =
    if note.len != posted.callerLen:
      return false
    for i in 0 ..< note.len:
      if note[i] != posted.caller[i]:
        return false
    true

  proc onPosted(
      name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
  ) {.cdecl, gcsafe, raises: [].} =
    let p = cast[ptr Posted](userData)
    if len == 0:
      p.bad += 1
      return
    let ev = LedgerPostedEvent.decode(toOpenArray(data, 0, int(len) - 1))
    if ev.isErr:
      p.bad += 1
      return
    let key = ev.get.key
    if key == "scoped":
      p.scoped.store(int(ev.get.total))
    elif key == "timer":
      p.timer.store(int(ev.get.total))
    if key == "scoped" or key == "reenter":
      # [IFC-0281, IFC-0282] Re-enters the provider from the delivering thread.
      let r = invoke(addr p.reenter, LedgerProbeRequest(channel: 1))
      {.cast(gcsafe).}:
        if r.isOk and callerIs(r.get.note):
          p.reentered += 1
    p.count += 1

  proc hear(h: var LogosRouteHandle, id: var LogosSubscriptionId): ErrorCode =
    if h.vtable == nil:
      return ecNotReady
    toResult(
      h.vtable.subscribe(
        addr h, cstring("ledger.posted_event"), onPosted, addr posted, addr id
      )
    ).code

  proc counted(n: int): bool =
    ## `n` deliveries handled, and no more after a pause.
    let came = waitUntil(
      proc(): bool =
        posted.count.load >= n,
      Answer,
    )
    sleep(50 * Slow)
    came and posted.count.load == n

  # Posting from many threads ------------------------------------------------------------

  type Poster = object ## One thread's handle and what its posts got.
    handle: LogosRouteHandle
    index: int
    ok: Atomic[int] ## posts whose total and thread were as expected
    thread: Atomic[uint64] ## the module thread its first answer named

  proc posts(p: ptr Poster) {.thread.} =
    ## Posts to its own key through its own handle (INTERFACE l.1980): the
    ## instance keeps the totals in a GC'd table on its module thread.
    let key = "t" & $p.index
    for i in 1 .. PostsPerThread:
      let r = p.handle.post(key)
      if r.isOk and r.get.total == uint64(i):
        if p.thread.load == 0:
          p.thread.store(r.get.thread)
        if p.thread.load == r.get.thread and r.get.thread != uint64(getThreadId()):
          p.ok += 1
    releasePerThread()

  proc postFrom(posters: var openArray[Poster]) =
    var threads: array[PosterThreads, Thread[ptr Poster]]
    for i in 0 ..< posters.len:
      createThread(threads[i], posts, addr posters[i])
    for i in 0 ..< posters.len:
      joinThread(threads[i])

  proc holds(p: ptr LogosRouteHandle) {.thread.} =
    ## Holds the instance's module thread (`probe` 19) until the case opens it.
    discard p[].probe(19)
    releasePerThread()

  # Prepared calls to its deferred surface (DECISIONS G338) -------------------------------
  #
  # Plain data in globals: completions run on the Runtime's threads.

  type Waited = object
    count: Atomic[int] ## completions
    code: Atomic[int] ## the last one's code
    note: array[64, char]
    noteLen: int

  var waited: array[3, Waited]

  proc onWaited(
      outcome: Result[LedgerWaitResponse, InvocationFailure], user: pointer
  ) {.nimcall, gcsafe, raises: [].} =
    let w = cast[ptr Waited](user)
    if outcome.isOk:
      let n = outcome.unsafeGet.note
      w.noteLen = min(n.len, w.note.len)
      for i in 0 ..< w.noteLen:
        w.note[i] = n[i]
      w.code.store(0)
    else:
      w.code.store(ord(outcome.unsafeError.code))
    w.count += 1

  proc noteOf(w: ptr Waited): string =
    for i in 0 ..< w.noteLen:
      result.add(w.note[i])

  proc prepared(
      h: RouteHandle, w: ptr Waited, request: LedgerWaitRequest, timeoutMs = 0'u64
  ): PreparedCall =
    ## `wait` through `h`, prepared and submitted.
    w.count.store(0)
    w.code.store(-1)
    w.noteLen = 0
    let c = h.prepareInvoke(request, onWaited, w, timeoutMs)
    check c.isOk
    if c.isOk:
      result = c.get
      result.submit()

  proc completed(w: ptr Waited): bool =
    waitUntil(
      proc(): bool =
        w.count.load >= 1,
      Answer,
    )

  # Signals and descriptors ----------------------------------------------------------------

  proc sigactionOf(
    sig: cint, act, old: ptr Sigaction
  ): cint {.importc: "sigaction", header: "<signal.h>".}

  proc sentinel(sig: cint) {.noconv.} =
    discard

  proc openFds(): int =
    for _ in walkDir("/dev/fd"):
      inc result

  # The cases ------------------------------------------------------------------------------

  suite "run.kit-mixed: a thread-confined kit built with the other memory manager (DECISIONS G342, G335-G339)":
    teardown:
      leftover()
      check noHostLeft()

    test "[IMPL-DECISION G342] [IMPL-DECISION G335] [IMPL-DECISION G337] [IFC-0281] [IFC-0282] MX-1 direct_dynamic in this process: two instances at once, each on its own module thread; 16 threads post at once; events to a subscriber that re-enters from the publishing thread, in a handler's scope, from a timer and after foreign threads' posts; the host's SIGPIPE kept; stops, re-creation and the descriptor count":
      instrumentedOnly()
      let cfg = hosted()
      for s in ["l1", "l2", "l3", "lc"]:
        discard cfg.stateOf(s)
      let e = fixtureEngine(cfg)
      # [DECISIONS G340, P5] The library is loaded with a sentinel SIGPIPE
      # handler in place, which it leaves as it was.
      var mark, own, now: Sigaction
      mark.sa_handler = sentinel
      discard sigemptyset(mark.sa_mask)
      check sigactionOf(SIGPIPE, addr mark, addr own) == 0
      let l1 = e.started(ledgerRecord(false, "l1"), "l1")
      check sigactionOf(SIGPIPE, addr own, addr now) == 0
      check now.sa_handler == sentinel
      let l2 = e.started(ledgerRecord(false, "l2"), "l2")
      let (c, rc) = e.startClient("c")
      resetPosted(c.instance)
      posted.reenter = rc.ledgerHandle("re", l1)
      var sub = rc.ledgerHandle("s", l1)
      var id: LogosSubscriptionId
      check sub.hear(id) == ecOk
      var posters: array[PosterThreads, Poster]
      for i in 0 ..< PosterThreads:
        posters[i].index = i
        posters[i].handle = rc.ledgerHandle("p" & $i, if i mod 2 == 0: l1 else: l2)
      postFrom(posters)
      for i in 0 ..< PosterThreads:
        check posters[i].ok.load == PostsPerThread
      # One module thread per instance.
      for i in 2 ..< PosterThreads:
        check posters[i].thread.load == posters[i mod 2].thread.load
      check posters[0].thread.load != posters[1].thread.load
      for i in 0 ..< PosterThreads:
        posters[i].handle.drop()
      # l1's posts, delivered from its publisher thread, except those its
      # kit refused with its queue full (64 events; G337).
      var h = rc.ledgerHandle("h", l1)
      let full = h.refused
      check full in 0 ..< PosterThreads div 2 * PostsPerThread
      var n = PosterThreads div 2 * PostsPerThread - full
      check counted(n)
      check h.post("reenter").isOk
      inc n
      check counted(n)
      check posted.reentered.load == 1
      # [P3] In the scope of a call through the subscribed route: delivered,
      # and the re-entry answered, before the call returns.
      check sub.probe(2, 7) == "ok"
      check posted.scoped.load == 7
      check posted.reentered.load == 2
      inc n
      # From a chronos timer on the module thread.
      check h.probe(21, 20) == "later"
      check waitUntil(
        proc(): bool =
          posted.timer.load == 20,
        Answer,
      )
      # Four foreign C threads post ten callbacks each; all run on the module
      # thread.
      check h.probe(7, 4) == "posted"
      check h.probeUntil(22, "40 0 ").startsWith("40 0 ")
      check counted(n + 1)
      check posted.bad.load == 0
      # [G335] Stopped with publications still queued: none is delivered
      # after the stop returns.
      for i in 0 ..< 50:
        check h.post("queued").isOk
      check e.stop("l1").tryGet.state == msUnloaded
      let after = posted.count.load
      sleep(100 * Slow)
      check posted.count.load == after
      h.drop()
      sub.drop()
      posted.reenter.drop()
      # The other instance is unaffected; a new one runs from the same
      # library, which stays loaded.
      var h2 = rc.ledgerHandle("h2", l2)
      let r2 = h2.post("t1")
      check r2.isOk and r2.get.total == uint64(PostsPerThread + 1)
      h2.drop()
      let l3 = e.started(ledgerRecord(false, "l3"), "l3")
      var h3 = rc.ledgerHandle("h3", l3)
      let r3 = h3.post("t0")
      check r3.isOk and r3.get.total == 1
      h3.drop()
      # [G335] Create and destroy cycles keep the open-descriptor count.
      discard e.started(ledgerRecord(false, "lc"), "lc")
      check e.stop("lc").tryGet.state == msUnloaded
      let fds = openFds()
      for _ in 0 ..< 10:
        check e.start("lc").tryGet.state == msReady
        check e.stop("lc").tryGet.state == msUnloaded
      check openFds() == fds
      e.finish()

    test "[IMPL-DECISION G342] [IMPL-DECISION G335] [IMPL-DECISION G337] [IFC-0281] [IFC-0282] MX-2 hosted_dynamic in a Module Host process: 16 threads post at once on their own sessions; events through the host's transport to a subscriber that re-enters from the delivering thread, in a handler's scope, from a timer and after foreign threads' posts; a restart in a new host":
      instrumentedOnly()
      let cfg = hosted()
      discard cfg.stateOf("hl")
      let e = fixtureEngine(cfg)
      let hl = e.started(ledgerRecord(true, "hl"), "hl")
      let (c, rc) = e.startClient("c")
      resetPosted(c.instance)
      posted.reenter = rc.ledgerHandle("re", hl)
      var sub = rc.ledgerHandle("s", hl)
      var id: LogosSubscriptionId
      check sub.hear(id) == ecOk
      var posters: array[PosterThreads, Poster]
      for i in 0 ..< PosterThreads:
        posters[i].index = i
        posters[i].handle = rc.ledgerHandle("p" & $i, hl)
      postFrom(posters)
      for i in 0 ..< PosterThreads:
        check posters[i].ok.load == PostsPerThread
        check posters[i].thread.load == posters[0].thread.load
        posters[i].handle.drop()
      var h = rc.ledgerHandle("h", hl)
      let full = h.refused
      check full in 0 ..< PosterThreads * PostsPerThread
      var n = PosterThreads * PostsPerThread - full
      check counted(n)
      check h.post("reenter").isOk
      inc n
      check counted(n)
      check posted.reentered.load == 1
      check sub.probe(2, 7) == "ok"
      inc n
      check counted(n)
      check posted.scoped.load == 7
      check posted.reentered.load == 2
      check h.probe(21, 20) == "later"
      check waitUntil(
        proc(): bool =
          posted.timer.load == 20,
        Answer,
      )
      check h.probe(7, 4) == "posted"
      check h.probeUntil(22, "40 0 ").startsWith("40 0 ")
      check counted(n + 1)
      check posted.bad.load == 0
      h.drop()
      sub.drop()
      posted.reenter.drop()
      # A restart: the host exits, and a new one loads the library again.
      check e.stop("hl").tryGet.state == msUnloaded
      check noHostLeft()
      check e.start("hl").tryGet.state == msReady
      var h2 = rc.ledgerHandle("h2", e.view("hl").tryGet)
      let r = h2.post("t0")
      check r.isOk and r.get.total == 1
      h2.drop()
      e.finish()

    test "[IMPL-DECISION G338] [IFC-0753] MX-4 prepared calls to its deferred surface (_MODULE_async_api), direct_dynamic and hosted: a completion with the consumer as caller, a cancellation that reaches its async handler, and a deadline that does":
      instrumentedOnly()
      for placeHosted in [false, true]:
        checkpoint (if placeHosted: "hosted" else: "direct")
        let cfg = hosted()
        discard cfg.stateOf("dl")
        let e = fixtureEngine(cfg)
        let l = e.started(ledgerRecord(placeHosted, "dl"), "dl")
        let (c, rc) = e.startClient("c")
        resetPosted(c.instance)
        var sync = rc.ledgerHandle("ks", l)
        let before = parseInt(sync.probe(23).split(' ')[0])
        let wrapped = wrapRoute(rc.ledgerHandle("kd", l))
        check wrapped.isOk
        let h = wrapped.get
        # A completion: the handler reads its caller through its Invocation.
        let a = h.prepared(addr waited[0], LedgerWaitRequest(channel: 1, millis: 1))
        check completed(addr waited[0])
        check waited[0].code.load == 0
        check callerIs(noteOf(addr waited[0]))
        check a.release().isOk
        # A cancellation, once the handler sleeps: the Runtime marks the
        # invocation and calls request_cancel, which cancels its future.
        let started = getMonoTime()
        let b =
          h.prepared(addr waited[1], LedgerWaitRequest(channel: 9, millis: 600_000))
        check sync.probeUntil(23, $before & " 1") == $before & " 1"
        b.cancel()
        check completed(addr waited[1])
        check waited[1].code.load == ord(ecCancelled)
        check sync.probeUntil(23, $(before + 1) & " 0") == $(before + 1) & " 0"
        check b.release().isOk
        # A deadline: TIMEOUT, and the provider's invocation is cancelled too.
        let d = h.prepared(
          addr waited[2],
          LedgerWaitRequest(channel: 9, millis: 600_000),
          timeoutMs = uint64(3000 * Slow),
        )
        check sync.probeUntil(23, $(before + 1) & " 1") == $(before + 1) & " 1"
        check completed(addr waited[2])
        check waited[2].code.load == ord(ecTimeout)
        check sync.probeUntil(23, $(before + 2) & " 0") == $(before + 2) & " 0"
        check getMonoTime() - started < initDuration(seconds = Answer)
        check d.release().isOk
        check h.release().isOk
        check sync.post("after").isOk
        sync.drop()
        check e.stop("dl").tryGet.state == msUnloaded
        e.finish()
        check noHostLeft()

    test "[IMPL-DECISION G342] [IMPL-DECISION G339] MX-3 as a consumer, direct_dynamic and hosted: its route to the meter through kit/routes; deliveries, a completion, a subscription the authority ended, one its full queue ended and the route's end reach its typed handlers on its module thread":
      instrumentedOnly()
      for placeHosted in [false, true]:
        let cfg = underAuthority()
        let dir = cfg.stateOf("l")
        writeFile(
          dir / "route.cmd", hexOf(meterRoot) & "\n" & hexOf(meterSchema) & "\n"
        )
        let e = fixtureEngine(cfg)
        e.startAuthority()
        discard e.started(meter(), "m")
        let l = e.started(ledgerRecord(placeHosted, "l"), "l")
        let (_, rc) = e.startClient("c")
        var m = rc.handle(rc.routeId("km"))
        var h = rc.ledgerHandle("kl", l)
        check h.probe(18) == "subscribed"
        # The meter publishes 150 on channel 15.
        check m.read(15).isOk
        check h.probeUntil(14, "seen=150 ").startsWith("seen=150 ")
        # A completion, on the module thread.
        check h.probe(13, 4) == "submitted"
        check " done=ok:" in h.probeUntil(14, " done=ok:")
        check h.probe(15) == "ok"
        if not placeHosted:
          # [P1] Its full queue ends the subscription, from inside the
          # delivery, which runs before the meter's publish returns: two
          # queued while the module thread is held, the third ends it.
          check h.probe(16, 2) == "bound"
          var hold: Thread[ptr LogosRouteHandle]
          var holder = rc.ledgerHandle("kh", l)
          createThread(hold, holds, addr holder)
          check waitUntil(
            proc(): bool =
              fileExists(dir / "held"),
            Answer,
          )
          for _ in 0 ..< 4:
            check m.read(15).isOk
          writeFile(dir / "open", "")
          joinThread(hold)
          holder.drop()
          check h.probeUntil(14, " end=MODULE_ERROR ").startsWith(
            "seen=150,150,150 end=MODULE_ERROR "
          )
          # [INTERFACE l.1482] Its unsubscribe after the end is OK.
          check h.probe(11) == "ok"
          check h.probe(16, 1024) == "bound"
          check h.probe(18) == "subscribed" # a second route
        # [G175, G225] The authority denies the next delivery: the binding
        # ends the subscription NOT_AUTHORISED, reported on the module thread.
        setScript(rule(vDeny, "subscribe-event"))
        check publish(PolicyChangedName, policyChanged(0, 1))
        check m.read(15).isOk
        check " end=NOT_AUTHORISED " in h.probeUntil(14, " end=NOT_AUTHORISED ")
        check h.probe(11) == "ok"
        setScript()
        # [INTERFACE l.1455] Its own close_route: the end is queued, never run
        # inside the call, and then reaches onRouteEnd on the module thread.
        check h.probe(20) == "ok route="
        check " route=NOT_READY " in h.probeUntil(14, " route=NOT_READY ")
        check h.probe(14).endsWith(" off=0")
        h.drop()
        m.drop()
        check e.stop("l").tryGet.state == msUnloaded
        e.finish()
        check noHostLeft()
