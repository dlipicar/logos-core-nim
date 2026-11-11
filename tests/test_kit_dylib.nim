## lcn-gen's module kit as a module ships [IMPL]: the kit modules of
## `tests/kit/` built as shared libraries (`--app:lib`), each with its own Nim
## runtime and its own `--nimMainPrefix`, loaded by this host with `dlopen` and
## called only through their exported symbols (INTERFACE §2.6), from the
## loading thread and from threads their runtimes have never seen (§2.8).
##
## In process (`tests/test_kit.nim`) the host and the module share one Nim
## runtime; here each library's runtime starts in a load-time constructor, as a
## module's does in a Runtime. The libraries are built when the suite starts,
## with this build's memory manager and mode.

import std/[dynlib, os, osproc, strutils, typedthreads]
import unittest2
import ../src/logos_core/iface/[accept, provider]
import ./support/[kitruntime, specdata]
import ./generated/[meter_module_types, sensor_module_types]

const
  mm =
    when compileOption("mm", "orc"):
      "orc"
    elif compileOption("mm", "refc"):
      "refc"
    elif compileOption("mm", "arc"):
      "arc"
    else:
      {.error: "test_kit_dylib: unknown memory manager".}
  variant = mm & (when defined(release): "-release" else: "")
  testsDir = currentSourcePath().parentDir
  nimExe = getCurrentCompilerExe()

type
  NameFn = proc(): cstring {.cdecl, gcsafe, raises: [].}
  InitFn = proc(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
  ): LogosResult {.cdecl, gcsafe, raises: [].}
  DestroyFn = proc(module: ptr LogosModuleContext) {.cdecl, gcsafe, raises: [].}
  CallSurfaceFn = proc(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].}

  Library = object ## One kit module's exported symbols, as `dlsym` finds them.
    name: NameFn
    init: InitFn
    destroy: DestroyFn
    callSurface: CallSurfaceFn
    free: FreeFn
    dispatch: DispatchFn

proc build(source, name: string): string =
  ## `tests/kit/<source>` as `lib<name>`; `--nimMainPrefix` keeps each
  ## library's `NimMain` distinct from the host's and the other library's.
  let dir = testsDir.parentDir / "build" / "kit-dylib" / variant
  createDir(dir)
  result = dir / (DynlibFormat % name)
  var args = @[nimExe, "c", "--hints:off", "--mm:" & mm]
  when defined(release):
    args.add("-d:release")
  args.add(
    [
      "--app:lib",
      "--nimMainPrefix:lib" & name,
      "--nimcache:" & dir / ("nimcache-" & name),
      "-o:" & result,
      testsDir / "kit" / source,
    ]
  )
  let (output, code) = execCmdEx(quoteShellCommand(args))
  doAssert code == 0, "building " & source & " failed:\n" & output

proc load(path, module: string): Library =
  let handle = loadLib(path)
  doAssert handle != nil, "dlopen failed: " & path
  template symbol(T: typedesc, suffix: string): untyped =
    let p = handle.symAddr(cstring("logos_" & module & "_MODULE_" & suffix))
    doAssert p != nil, "missing symbol " & module & " " & suffix
    cast[T](p)

  Library(
    name: symbol(NameFn, "name"),
    init: symbol(InitFn, "init"),
    destroy: symbol(DestroyFn, "destroy"),
    callSurface: symbol(CallSurfaceFn, "call_surface"),
    free: symbol(FreeFn, "free"),
    dispatch: symbol(DispatchFn, "dispatch"),
  )

let
  meter = load(build("meter_impl.nim", "kitmeter"), "meter_module")
  sensor = load(build("sensor_impl.nim", "kitsensor"), "sensor_module")

proc start(lib: Library): ptr LogosModuleContext {.gcsafe.} =
  var i = input()
  let r = lib.init(addr i, addr result)
  doAssert checkOutcome(r, contextShape(result)).isOk, "init failed"

proc read(channel: uint32): seq[byte] =
  encode(MeterReadRequest(channel: channel)).get

proc reading(channel: uint32): seq[byte] =
  ## The response of `read(channel)` for a plain channel.
  encode(
    MeterReadResponse(
      label: "ch" & $channel, reading: MeterReading(value: uint64(channel) * 10)
    )
  ).get

suite "ifc.kit: kit modules as shared libraries (INTERFACE §2.6, §2.8) [IMPL]":
  test "two libraries load side by side and report their identity and call surface":
    check $meter.name() == "meter_module"
    check $sensor.name() == "sensor_module"
    var n: csize_t
    let p = meter.callSurface(addr n)
    let bytes = @(cast[ptr UncheckedArray[uint8]](p).toOpenArray(0, int(n) - 1))
    let b = acceptBinding(
      "meter_module", Opt.some(mirror("IFC/3.9.1.module.cddl")), [], []
    ).get
    check bytes == callSurfaceDescriptor(b).get

  test "calls from the loading thread: a response, a failure's message, an event":
    withLock publishedLock:
      published.setLen(0)
    let ctx = meter.start()
    let ok4 = call(meter.dispatch, meter.free, ctx, "read", read(4))
    check ok4.status.isOk and ok4.response == reading(4)
    let failed = call(meter.dispatch, meter.free, ctx, "read", read(13))
    check failed.code == ecModule
    check failed.status.error.message == Opt.some("channel 13 is broken")
    check call(meter.dispatch, meter.free, ctx, "read", read(15)).status.isOk
    withLock publishedLock:
      check published == @[("meter.changed_event", diag("{\"value\": 150}"), "plain")]
    meter.destroy(ctx)
    let s = sensor.start()
    let configure = encode(
      SensorNSControlConfigureRequest(settings: SensorNSControlSettings(limit: 9))
    ).get
    check call(sensor.dispatch, sensor.free, s, "configure", configure).status.isOk
    let snap = call(
      sensor.dispatch,
      sensor.free,
      s,
      "snapshot",
      encode(MetricsProviderSnapshotRequest()).get,
    )
    check snap.status.isOk
    check MetricsProviderSnapshotResponse.decode(snap.response).get.count == 1
    sensor.destroy(s)

  test "[IFC-0259] [IFC-0265] calls from threads the library's runtime has not seen":
    ## Under orc the context is also created and destroyed on such threads;
    ## under refc (one heap per thread) on the loading thread (`kitrt`).
    const
      workers = 4
      rounds = 100
    var failures: Atomic[int]

    proc worker(args: (ptr LogosModuleContext, ptr Atomic[int])) {.thread.} =
      let (ctx, failures) = args
      for k in 0 ..< rounds:
        let ch = uint32(k mod 10)
        let c = call(meter.dispatch, meter.free, ctx, "read", read(ch))
        if not c.status.isOk or c.response != reading(ch):
          failures[] += 1
        let e = call(meter.dispatch, meter.free, ctx, "read", read(13))
        if e.code != ecModule or
            e.status.error.message != Opt.some("channel 13 is broken"):
          failures[] += 1

    proc starter(args: (ptr ptr LogosModuleContext, int)) {.thread.} =
      args[0][] = meter.start()

    proc stopper(args: (ptr LogosModuleContext, int)) {.thread.} =
      meter.destroy(args[0])

    var ctx: ptr LogosModuleContext
    when defined(gcDestructors):
      var t: Thread[(ptr ptr LogosModuleContext, int)]
      createThread(t, starter, (addr ctx, 0))
      joinThread(t)
    else:
      ctx = meter.start()
    var threads: array[workers, Thread[(ptr LogosModuleContext, ptr Atomic[int])]]
    for t in threads.mitems:
      createThread(t, worker, (ctx, addr failures))
    joinThreads(threads)
    check failures.load == 0
    when defined(gcDestructors):
      var t2: Thread[(ptr LogosModuleContext, int)]
      createThread(t2, stopper, (ctx, 0))
      joinThread(t2)
    else:
      meter.destroy(ctx)
