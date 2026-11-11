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
import ./support/[kitruntime, specdata, typedharness]
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
    handle: LibHandle
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
    handle: handle,
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
  shapes = load(build("shapes_impl.nim", "kitshapes"), "shapes_module")

proc typedSymbol(lib: Library, name: string): pointer =
  ## A typed provider function (INTERFACE §2.4) the library exports.
  result = lib.handle.symAddr(cstring(name))
  doAssert result != nil, "missing symbol " & name

let typed = ThFns(
  meterRead: meter.typedSymbol("logos_meter_module_CALL_meter_Read"),
  sensorConfigure:
    sensor.typedSymbol("logos_sensor_module_CALL_sensor_NS_control_Configure"),
  sensorSnapshot:
    sensor.typedSymbol("logos_sensor_module_CALL_metrics_provider_Snapshot"),
  shapesReflect: shapes.typedSymbol("logos_shapes_module_CALL_shapes_Reflect"),
  shapesPick: shapes.typedSymbol("logos_shapes_module_CALL_shapes_Pick"),
  shapesPing: shapes.typedSymbol("logos_shapes_module_CALL_shapes_Ping"),
)

proc start(lib: Library, publish = true): ptr LogosModuleContext {.gcsafe.} =
  var i = input(publish = publish)
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

  test "[IFC-0164] [IFC-0162] typed provider functions through the libraries' exports":
    let m = meter.start()
    let r4 = typedRead(typed, m, 4)
    check r4.status.isOk and r4.owned
    check r4.text == "label=\"ch4\" reading=(absent,40)"
    let r13 = typedRead(typed, m, 13)
    check r13.code == ecModule and r13.untouched
    check r13.message == "channel 13 is broken"
    meter.destroy(m)
    let s = sensor.start(publish = false)
    check typedConfigure(typed, s, "sensor", 3).status.isOk
    check typedSnapshot(typed, s).text == "count=1"
    sensor.destroy(s)
    let sh = shapes.start(publish = false)
    for v in [rvFull, rvAbsent, rvEmpty, rvNumbers, rvDeep]:
      let t = typedReflect(typed, sh, v)
      checkpoint $v & ": " & t.message
      check t.status.isOk and t.same
    for v in [rvNullText, rvBadKind, rvCycle, rvNullRecursive, rvTooDeep]:
      let t = typedReflect(typed, sh, v)
      check t.code == ecInvalidParams and t.untouched
    check typedPick(typed, sh, pvName).text ==
      "found=true entry=dir{kind=\"dir\" path=\"/nm\" entries=[\"nm\",\"nm\"]}"
    check typedPing(typed, sh).status.isOk
    check typedReflectCleared(typed, sh).same
    shapes.destroy(sh)

  test "[IFC-0265] [IFC-0694] typed calls from threads the library's runtime has not seen; owners cleared on others":
    const
      workers = 4
      rounds = 40
    var failures: Atomic[int]
    var held: array[workers * rounds, LogosResponseOwner]

    proc caller(
        args: (ptr LogosModuleContext, ptr Atomic[int], ptr LogosResponseOwner, int)
    ) {.thread.} =
      let (ctx, failures, owners, id) = args
      let owned = cast[ptr UncheckedArray[LogosResponseOwner]](owners)
      for k in 0 ..< rounds:
        let t = typedReflect(typed, ctx, rvFull, keep = true)
        if not (t.status.isOk and t.same and t.owned):
          failures[] += 1
        owned[id * rounds + k] = t.owner
        let bad = typedReflect(typed, ctx, rvBadUtf8)
        if bad.code != ecInvalidParams or not bad.untouched:
          failures[] += 1

    proc clearer(args: (ptr LogosResponseOwner, int)) {.thread.} =
      let owned = cast[ptr UncheckedArray[LogosResponseOwner]](args[0])
      for k in 0 ..< rounds:
        clear(owned[args[1] * rounds + k])

    let ctx = shapes.start(publish = false)
    var threads: array[
      workers,
      Thread[(ptr LogosModuleContext, ptr Atomic[int], ptr LogosResponseOwner, int)],
    ]
    for i in 0 ..< workers:
      createThread(threads[i], caller, (ctx, addr failures, addr held[0], i))
    joinThreads(threads)
    check failures.load == 0
    var clearers: array[workers, Thread[(ptr LogosResponseOwner, int)]]
    for i in 0 ..< workers:
      # each clears another caller's owners
      createThread(clearers[i], clearer, (addr held[0], (i + 1) mod workers))
    joinThreads(clearers)
    for o in held:
      check ownerEmpty(o)
    shapes.destroy(ctx)

  test "[IFC-0927] a typed call at the payload depth limit on a thread with 1 MiB of stack [IMPL]":
    let ctx = shapes.start(publish = false)
    let deepest = typedReflectOnStack(typed, ctx, rvDeepest, 1 shl 20)
    check deepest.status.isOk and deepest.same
    let tooDeep = typedReflectOnStack(typed, ctx, rvTooDeep, 1 shl 20)
    check tooDeep.code == ecInvalidParams and tooDeep.untouched
    shapes.destroy(ctx)
