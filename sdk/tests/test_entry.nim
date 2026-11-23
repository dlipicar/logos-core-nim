## The foreign-thread entry rule (DECISIONS G464-G467): the marks' compile-time
## gate, the probe on fresh threads (`logos_sdk/testing/freshthread`), the
## control that must die, each SDK exemption run on a thread that never
## registered, and the module-thread assertion. POSIX only: fresh C threads
## and a child process.
##
## The child is this program run again with a case in `LCN_TEST_ENTRY_CHILD`,
## so that a fault or an abort ends it and not the suite. `lcn_kit_post`'s
## exemption is run on threads that never registered by test_kit_confined's
## foreign posters (`lcn_foreign_post`); the core's exemptions call only what
## the exempt case runs here (`releaseGiven`, the C allocator, a thread
## variable) or nothing.

when defined(posix):
  import std/[atomics, os, osproc, posix, streams, strutils]
  import unittest2
  import logos_sdk/abi/[cstatus, types]
  import logos_sdk/base/entry
  import logos_sdk/codegen/[callrt, confinedrt]
  import logos_sdk/kit/rcclient
  import logos_sdk/testing/freshthread
  import logos_sdk/testing/fixtures/[ledger_impl, meter_impl]
  import logos_sdk/testing/generated/meter_module_calls

  exportMeterModuleCalls()

  const
    childVar = "LCN_TEST_ENTRY_CHILD"
    faultIsCertain = defined(gcDestructors) and not defined(useMalloc)
      ## orc or arc without `useMalloc`: an unregistered thread's first
      ## allocation faults (DECISIONS I77 (7)); refc and the sanitizer builds
      ## have no per-thread region to miss.

  var
    delivered: Atomic[int]
    lastLen: Atomic[int]

  let nothing: seq[byte] = @[]

  # The callbacks -------------------------------------------------------------------

  proc markedEvent(
      name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
  ) {.lcnCallback.} =
    ## Allocates: a string and a sequence on the Nim heap.
    var s = $name
    var b = newSeq[byte](int(len))
    for i in 0 ..< int(len):
      b[i] = data[i]
    lastLen.store(s.len + b.len)
    discard delivered.fetchAdd(1)

  proc markedRouteEnd(reason: CErrorCode, userData: pointer) {.lcnCallback.} =
    var s = newString(16)
    s[0] = 'e'
    discard delivered.fetchAdd(1)

  proc markedSubEnd(
      id: LogosSubscriptionId, reason: CErrorCode, userData: pointer
  ) {.lcnCallback.} =
    ## A doc comment first: the registration still comes before the body.
    var s = @[int64(id), int64(reason)]
    lastLen.store(s.len)
    discard delivered.fetchAdd(1)

  proc markedComplete(
      userData: pointer,
      status: LogosResult,
      response: ptr UncheckedArray[uint8],
      len: csize_t,
      owner: LogosResponseOwner,
  ) {.lcnCallback.} =
    var copy = newSeq[byte](int(len))
    for i in 0 ..< int(len):
      copy[i] = response[i]
    lastLen.store(copy.len)
    if not owner.release.isNil:
      owner.release(owner.state)
    discard delivered.fetchAdd(1)

  proc quietEvent(
      name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
  ) {.cdecl, gcsafe, raises: [].} =
    ## Unmarked, and allocates nothing: it returns, and the probe says so.
    discard delivered.fetchAdd(1)

  proc unmarkedAllocating(
      name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
  ) {.cdecl, gcsafe, raises: [].} =
    ## Unmarked, and allocates: G339's completion. The control.
    var s = newString(64)
    s[0] = 'x'
    lastLen.store(s.len)

  proc rawComplete(
      userData: pointer,
      status: LogosResult,
      response: ptr UncheckedArray[uint8],
      len: csize_t,
      owner: LogosResponseOwner,
  ) {.cdecl, gcsafe, raises: [].} =
    discard

  proc rawPost(payload: pointer) {.cdecl, gcsafe, raises: [].} =
    discard

  proc onModule(payload: pointer) {.lcnModuleThread.} =
    discard delivered.fetchAdd(1)

  # The exempt procedures, each on a fresh thread ----------------------------------

  type
    GetterKind = enum
      gkName
      gkSurface
      gkAsyncApi

    GetterJob = object
      kind: GetterKind
      fn: pointer
      name: cstring
      bytes: pointer
      len: csize_t

    ClearJob = object
      owner: LogosResponseOwner

    GivenJob = object
      buf: ptr UncheckedArray[uint8]

  proc runGetter(arg: pointer) {.cdecl, gcsafe, raises: [].} =
    let j = cast[ptr GetterJob](arg)
    case j.kind
    of gkName:
      j.name = cast[ModuleNameFn](j.fn)()
    of gkSurface:
      j.bytes = cast[ModuleCallSurfaceFn](j.fn)(addr j.len)
    of gkAsyncApi:
      j.bytes = cast[ModuleAsyncApiFn](j.fn)()

  proc runClear(arg: pointer) {.cdecl, gcsafe, raises: [].} =
    let j = cast[ptr ClearJob](arg)
    meterModuleCallsClear0(addr j.owner, nil, nil)

  proc runReleaseGiven(arg: pointer) {.cdecl, gcsafe, raises: [].} =
    releaseGiven(cast[ptr GivenJob](arg).buf)

  proc say(line: string) =
    try:
      stdout.writeLine(line)
      stdout.flushFile()
    except IOError:
      discard

  proc exemptChild(): int =
    ## Each exemption the SDK claims, on a thread that never registered: it
    ## must return, register nothing, and answer what it answers on any
    ## thread. The number that failed.
    for (sym, p) in ledgerModuleStaticSymbols() & meterModuleStaticSymbols():
      let kind =
        if sym.endsWith("_MODULE_name"):
          gkName
        elif sym.endsWith("_MODULE_call_surface"):
          gkSurface
        elif sym.endsWith("_MODULE_async_api"):
          gkAsyncApi
        else:
          continue
      var j = GetterJob(kind: kind, fn: p)
      let entered = onFreshThread(runGetter, addr j)
      let answered =
        case kind
        of gkName:
          j.name != nil and sym.startsWith("logos_" & $j.name & "_MODULE_")
        of gkSurface:
          j.bytes != nil and j.len > 0
        of gkAsyncApi:
          j.bytes != nil
      if entered or not answered:
        inc result
      say("exempt " & sym & ": " & (if entered or not answered: "FAILED" else: "ok"))
    # The clear helper, through a response owner whose release is the call
    # arena's (`releaseBlocks`).
    let before = arenaBlocks()
    var arena: CallArena
    discard arena.alloc(48).get
    discard arena.alloc(4096).get
    var clear = ClearJob(owner: arena.owner)
    let clearEntered = onFreshThread(runClear, addr clear)
    let cleared = clear.owner.release.isNil and arenaBlocks() == before
    if clearEntered or not cleared:
      inc result
    say(
      "exempt lcn_clear_meter_Read: " &
        (if clearEntered or not cleared: "FAILED" else: "ok")
    )
    # The call arena's release itself.
    var arena2: CallArena
    discard arena2.alloc(100).get
    let released = freshRelease(arena2.owner)
    if released or arenaBlocks() != before:
      inc result
    say(
      "exempt releaseBlocks: " &
        (if released or arenaBlocks() != before: "FAILED" else: "ok")
    )
    # A confined completion's response owner (`releaseBlock`).
    let blockReleased = freshRelease(blockOwnerForTests([1'u8, 2, 3, 4, 5]))
    if blockReleased:
      inc result
    say("exempt releaseBlock: " & (if blockReleased: "FAILED" else: "ok"))
    # `releaseGiven`, all the Runtime's and the host's response releases do.
    var given = GivenJob()
    var givenLen: csize_t
    discard give([9'u8, 8, 7], addr given.buf, addr givenLen)
    let givenEntered = onFreshThread(runReleaseGiven, addr given)
    if givenEntered:
      inc result
    say("exempt releaseGiven: " & (if givenEntered: "FAILED" else: "ok"))

  proc child(name: string) =
    defaultSignals()
    case name
    of "control":
      discard freshEvent(unmarkedAllocating, "x", [1'u8], nil)
      say("control: returned")
      quit(0)
    of "exempt":
      quit(if exemptChild() == 0: 0 else: 1)
    of "offthread":
      discard onFreshThread(onModule, nil)
      say("offthread: returned")
      quit(0)
    else:
      quit(3)

  if existsEnv(childVar):
    child(getEnv(childVar))

  proc inChild(name: string, seconds = 120): tuple[code: int, output: string] =
    ## This program run again with `name`, its exit code as a shell gives it
    ## (128 and the signal for a signal); -1 when it was still running after
    ## `seconds` and was killed.
    putEnv(childVar, name)
    try:
      let p = startProcess(getAppFilename(), options = {poStdErrToStdOut})
      try:
        var waited = 0
        while p.running and waited < seconds * 1000:
          sleep(20)
          waited += 20
        if p.running:
          p.kill()
          discard p.waitForExit()
          result.code = -1
        else:
          result.code = p.waitForExit()
        result.output = p.outputStream.readAll()
      finally:
        p.close()
    finally:
      delEnv(childVar)

  suite "entry: the marks' gate (DECISIONS G464, G465)":
    test "[IMPL-DECISION G464] entered refuses an unmarked procedure, at compile time":
      check not compiles(entered(rawComplete))
      check not compiles(entered(rawPost))
      check compiles(entered(markedComplete))
      check compiles(entered(onModule))

    test "[IMPL-DECISION G464] rcclient's helpers take entered procedures only, of the right kind":
      let rc: ptr LogosRuntimeControlBinding = nil
      var call: LogosAsyncCall
      let params = @[0xa0'u8]
      check compiles(prepareBytes(rc, "m", params, entered(markedComplete), nil, call))
      check not compiles(prepareBytes(rc, "m", params, rawComplete, nil, call))
      check not compiles(prepareBytes(rc, "m", params, entered(markedEvent), nil, call))
      check compiles(subscribe(rc, "e", entered(markedEvent), nil))
      check not compiles(subscribe(rc, "e", markedEvent, nil))
      check not compiles(subscribe(rc, "e", entered(markedComplete), nil))

    test "[IMPL-DECISION G465] post takes an entered module-thread procedure":
      let p = Poster(nil)
      check compiles(post(p, entered(onModule), nil))
      check not compiles(post(p, rawPost, nil))
      check not compiles(post(p, entered(markedEvent), nil))

  suite "entry: the probe on fresh threads (DECISIONS G466)":
    setup:
      delivered.store(0)

    test "[IMPL-DECISION G466] a marked callback of each kind registers the fresh thread first, then allocates":
      check freshEvent(markedEvent, "ev", [1'u8, 2, 3], nil)
      check lastLen.load == 5
      check freshRouteEnd(markedRouteEnd, CErrorCode(0), nil)
      check freshSubscriptionEnd(markedSubEnd, 7, CErrorCode(0), nil)
      check lastLen.load == 2
      var arena: CallArena
      discard arena.alloc(32).get
      check freshCompletion(markedComplete, nil, LogosResult(), [4'u8, 5], arena.owner)
      check lastLen.load == 2
      check delivered.load == 4

    test "[IMPL-DECISION G466] an unmarked callback that allocates nothing returns, and the probe says it did not register":
      check not freshEvent(quietEvent, "ev", nothing, nil)
      check delivered.load == 1

    test "[IMPL-DECISION G466] the probe reads the calling thread only":
      check not onFreshThread(rawPost, nil)
      check freshEvent(markedEvent, "a", nothing, nil)
      check not freshEvent(quietEvent, "b", nothing, nil) # a new thread each time

  suite "entry: in a child process (DECISIONS G464, G465, G467)":
    test "[IMPL-DECISION G464] the control: an unmarked callback that allocates dies on a fresh thread":
      when faultIsCertain:
        let (code, output) = inChild("control")
        check code in [128 + int(SIGSEGV), 128 + int(SIGBUS)]
        check "control: returned" notin output
      else:
        skip() # refc and useMalloc: no per-thread region, no certain fault

    test "[IMPL-DECISION G467] each SDK exemption runs on a thread that never registered":
      let (code, output) = inChild("exempt")
      check code == 0
      check ": FAILED" notin output
      for s in [
        "exempt logos_ledger_module_MODULE_name: ok",
        "exempt logos_ledger_module_MODULE_call_surface: ok",
        "exempt logos_ledger_module_MODULE_async_api: ok",
        "exempt logos_meter_module_MODULE_name: ok",
        "exempt logos_meter_module_MODULE_call_surface: ok",
        "exempt lcn_clear_meter_Read: ok", "exempt releaseBlocks: ok",
        "exempt releaseBlock: ok", "exempt releaseGiven: ok",
      ]:
        check s in output
      if code != 0 or ": FAILED" in output:
        echo output

    test "[IMPL-DECISION G465] a module-thread procedure called on another thread aborts with its name":
      let (code, output) = inChild("offthread")
      check code == 128 + int(SIGABRT)
      check "lcnModuleThread: onModule ran off its module thread (DECISIONS G465)" in
        output
      check "offthread: returned" notin output
else:
  import unittest2

  suite "entry: fresh threads (POSIX only)":
    test "[IMPL] the fresh-thread cases need POSIX threads and a child process":
      skip()
