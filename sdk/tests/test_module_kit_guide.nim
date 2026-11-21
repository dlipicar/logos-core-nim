## The module kit's author's guide, `sdk/docs/MODULE-KIT.md` (DECISIONS I101,
## step N-1 sub-part 6): its example is taken from the guide's own code blocks
## (the contract, the implementation, the generate line and this platform's
## build line), generated with lcn-gen, built as a library exactly as the guide
## says and called as a Runtime calls a module: through its exported symbols.
##
## The guide builds a refc library. Under MemorySanitizer the case skips: the
## library is not instrumented, and what it writes reads as uninitialized
## (DECISIONS I77, G342).

when defined(linux) or defined(macosx):
  import std/[dynlib, locks, os, osproc, strutils, tables]
  import unittest2
  import logos_sdk/abi/[checks, types]
  import logos_sdk/iface/outcome
  import logos_sdk/testing/[kitbuild, kitruntime, testdirs]

  type
    NameFn = proc(): cstring {.cdecl, gcsafe, raises: [].}
    InitFn = proc(
      input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    DestroyFn = proc(module: ptr LogosModuleContext) {.cdecl, gcsafe, raises: [].}

  const
    Guide = "sdk/docs/MODULE-KIT.md"
    Platform = (when defined(macosx): "macos" else: "linux")

  let work = repoDir / "build" / "module-kit-guide" / kitVariant
    # under the repository, so its config.nims puts the SDK on the path

  type Recorded = object
    len: int
    bytes: array[64, byte]

  var
    eventsLock: Lock
    recorded: array[8, Recorded] ## the `counter.changed_event` payloads, in order
    recordedCount, otherEvents: int
  initLock(eventsLock)

  proc recordChanged(
      userData: pointer,
      eventName: cstring,
      cborData: ptr UncheckedArray[uint8],
      cborDataLen: csize_t,
  ): CErrorCode {.cdecl, gcsafe, raises: [].} =
    ## The host's publish callback. It runs on the library's publisher thread,
    ## which this program's Nim runtime has never seen, so it copies into fixed
    ## storage and allocates nothing.
    {.cast(gcsafe).}:
      acquire(eventsLock)
      if eventName == cstring("counter.changed_event") and recordedCount < recorded.len and
          int(cborDataLen) <= recorded[0].bytes.len:
        recorded[recordedCount].len = int(cborDataLen)
        for k in 0 ..< int(cborDataLen):
          recorded[recordedCount].bytes[k] = cborData[k]
        inc recordedCount
      else:
        inc otherEvents
      release(eventsLock)
    CErrorCode(0)

  proc changed(k: int): seq[byte] =
    withLock eventsLock:
      result = @(recorded[k].bytes.toOpenArray(0, recorded[k].len - 1))

  proc blocks(): Table[string, string] =
    ## The guide's fenced code blocks by their info string (`nim counter_impl.nim`).
    var info = ""
    var text = ""
    var inside = false
    for line in readFile(repoDir / Guide).splitLines:
      if line.startsWith("```"):
        if inside:
          result[info] = text
          inside = false
        else:
          info = line[3 .. ^1].strip
          text = ""
          inside = true
      elif inside:
        text.add(line & "\n")

  proc words(command: string): seq[string] =
    ## A command block's words, its `\` continuations joined.
    command.replace("\\\n", " ").splitWhitespace

  proc run(args: seq[string], dir: string): (string, int) =
    let (output, code) =
      execCmdEx(quoteShellCommand(args), options = {poStdErrToStdOut}, workingDir = dir)
    checkpoint(args.join(" ") & "\n" & output)
    (output, code)

  suite "ifc.kit: the module kit's author's guide (sdk/docs/MODULE-KIT.md; DECISIONS I101) [IMPL]":
    test "[IMPL-DECISION G335] [IMPL-DECISION G338] [IMPL-DECISION G341] the guide's example, generated and built as it says: a confined refc module whose state stays on its module thread, an async handler with its caller, queued events, and an ABI-only export list":
      when defined(msan):
        skip()
      else:
        let b = blocks()
        for info in [
          "cddl counter_module.cddl",
          "nim counter_impl.nim",
          "sh generate",
          "sh " & Platform,
        ]:
          check info in b
        removeDir(work)
        createDir(work)
        writeFile(work / "counter_module.cddl", b["cddl counter_module.cddl"])
        writeFile(work / "counter_impl.nim", b["nim counter_impl.nim"])

        # lcn-gen, under a name of its own so test_nimgen's build never races it.
        let lcnGen = repoDir / "build" / "tools" / "lcn_gen_guide"
        check run(
          @[
            getCurrentCompilerExe(),
            "c",
            "--hints:off",
            "--nimcache:" & repoDir / "build" / "nimcache" / "lcn_gen_guide",
            "-o:" & lcnGen,
            repoDir / "src" / "lcn_gen.nim",
          ],
          repoDir,
        )[1] == 0
        var generate = words(b["sh generate"])
        check generate[0] == "lcn-gen"
        generate[0] = lcnGen
        check run(generate, work)[1] == 0
        for name in [
          "counter_module_types.nim", "counter_module_kit.nim",
          "counter_module_kit.exports", "counter_module_kit.map",
        ]:
          check fileExists(work / "generated" / name)

        # The build line, with this toolchain and a nimcache of its own.
        var build = words(b["sh " & Platform])
        check build[0] == "nim" and build[1] == "c"
        build[0] = getCurrentCompilerExe()
        build =
          build[0 .. 1] & @["--hints:off", "--nimcache:" & work / "nimcache"] &
          build[2 .. ^1]
        check run(build, work)[1] == 0
        let lib =
          work / ("libcounter_module." & (when defined(macosx): "dylib" else: "so"))
        check fileExists(lib)

        let h = loadLib(lib)
        check h != nil
        template symbol(T: typedesc, name: string): untyped =
          cast[T](h.symAddr(cstring("logos_counter_module_MODULE_" & name)))

        let
          name = symbol(NameFn, "name")
          init = symbol(InitFn, "init")
          destroy = symbol(DestroyFn, "destroy")
          dispatch = symbol(DispatchFn, "dispatch")
          free = symbol(FreeFn, "free")
        check not name.isNil and not init.isNil and not destroy.isNil
        check not dispatch.isNil and not free.isNil
        check not h.symAddr("logos_counter_module_MODULE_async_api").isNil
        # [G341] Its ABI and nothing else: not its own Nim runtime's entry.
        check h.symAddr("libcounterNimMain").isNil
        check $name() == "counter_module"

        var i = input(publish = true)
        i.publish = recordChanged
        i.publishUserData = nil
        var ctx: ptr LogosModuleContext
        check checkOutcome(init(addr i, addr ctx), contextShape(ctx)).isOk
        let first = call(
          dispatch, free, ctx, "increment", diag("{\"key\": \"k\", \"amount\": 5}")
        )
        check first.status.isOk and first.response == diag("{\"total\": 5}")
        let second = call(
          dispatch, free, ctx, "increment", diag("{\"key\": \"k\", \"amount\": 3}")
        )
        check second.status.isOk and second.response == diag("{\"total\": 8}")
        check call(
          dispatch, free, ctx, "increment", diag("{\"key\": \"k\", \"amount\": 0}")
        ).code == ecInvalidParams
        # The async handler, with a caller made current around the entry.
        var current =
          LogosInvocationContext(vtable: addr contextVtable, state: addr contextState)
        activeContext = addr current
        let settled =
          call(dispatch, free, ctx, "settle", diag("{\"key\": \"k\", \"millis\": 5}"))
        activeContext = nil
        check settled.status.isOk
        check settled.response ==
          diag("{\"total\": 8, \"caller\": \"" & consumerId & "\"}")
        # [G337] Queued events are delivered by the time destroy returns.
        destroy(ctx)
        withLock eventsLock:
          check recordedCount == 3 and otherEvents == 0
        check changed(0) == diag("{\"key\": \"k\", \"total\": 5}")
        check changed(1) == diag("{\"key\": \"k\", \"total\": 8}")
        check changed(2) == diag("{\"key\": \"k\", \"total\": 8}")
else:
  import unittest2

  suite "ifc.kit: the module kit's author's guide (sdk/docs/MODULE-KIT.md; DECISIONS I101) [IMPL]":
    test "[IMPL] the guide's build lines are for Linux and macOS":
      skip()
