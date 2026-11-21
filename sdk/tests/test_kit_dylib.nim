## lcn-gen's module kit as a module ships [IMPL]: the kit modules of
## `tests/kit/` built as shared libraries (`--app:lib`), each with its own Nim
## runtime and its own `--nimMainPrefix`, loaded by this host with `dlopen` and
## called only through their exported symbols (INTERFACE §2.6), from the
## loading thread and from threads their runtimes have never seen (§2.8).
##
## In process (`sdk/tests/test_kit.nim`) the host and the module share one Nim
## runtime; here each library's runtime starts in a load-time constructor, as a
## module's does in a Runtime. The libraries are built when the suite starts,
## with this build's memory manager and mode.
##
## A fourth library exports the modules' typed call helpers (§2.7.2, App A.5),
## which this host calls through route handles bound directly to the module
## libraries (`support/testroute`): caller, helpers and provider then each run
## on a Nim runtime of their own.

import std/[dynlib, os, osproc, strutils, typedthreads]
import unittest2
import logos_sdk/base/perthread
import logos_sdk/iface/[accept, provider]
from logos_sdk/kit/rc_types import LogosNSModuleConfigurationConfigurationInput, encode
import
  logos_sdk/testing/[kitbuild, kitruntime, specdata, tunerconfig],
  ./support/[fakeprovider, testroute, typedharness]
import logos_sdk/testing/testdirs
import
  logos_sdk/testing/generated/
    [ledger_module_types, meter_module_types, sensor_module_types, tuner_module_types]

type
  NameFn = proc(): cstring {.cdecl, gcsafe, raises: [].}
  InitFn = proc(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
  ): LogosResult {.cdecl, gcsafe, raises: [].}
  DestroyFn = proc(module: ptr LogosModuleContext) {.cdecl, gcsafe, raises: [].}
  CallSurfaceFn = proc(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].}
  ApplyFn = proc(
    module: ptr LogosModuleContext, cbor: ptr UncheckedArray[uint8], len: csize_t
  ): LogosResult {.cdecl, gcsafe, raises: [].}
  SnapshotFn = proc(
    module: ptr LogosModuleContext, owner: ptr LogosResponseOwner, outCount: ptr uint64
  ): LogosResult {.cdecl, gcsafe, raises: [].}
    ## `metrics_provider.snapshot`'s typed provider function (INTERFACE §2.4)

  Library = object ## One kit module's exported symbols, as `dlsym` finds them.
    handle: LibHandle
    name: NameFn
    init: InitFn
    destroy: DestroyFn
    callSurface: CallSurfaceFn
    free: FreeFn
    dispatch: DispatchFn

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

proc build(source, name, module: string): Library =
  ## The kit library, linked with its kit's export list (DECISIONS G341).
  load(buildKitLibrary(source, name, exports = module), module)

const leftoverChildVar = "LCN_KIT_LEFTOVER_CHILD"

proc leftoverChild(spec: string) =
  ## [DECISIONS G438] The leftover cases' child, this program run again with
  ## `<library>|<channel>` in `LCN_KIT_LEFTOVER_CHILD`: it loads the confined
  ## ledger library, says which chronos it was built with, runs `probe` with
  ## the channel unless it is 0, destroys the instance and says so. A strict
  ## library aborts in that destroy instead.
  let at = spec.rfind('|')
  let lib = load(spec[0 ..< at], "ledger_module")
  var inp = input()
  var ctx: ptr LogosModuleContext
  doAssert lib.init(addr inp, addr ctx).code == CErrorCode(0)
  proc probe(channel: uint32): string =
    let c = call(
      lib.dispatch,
      lib.free,
      ctx,
      "probe",
      encode(LedgerProbeRequest(channel: channel)).get,
    )
    doAssert c.code == ecOk
    LedgerProbeResponse.decode(c.response).get.note

  stdout.writeLine("chronos: " & probe(27))
  let channel = uint32(parseInt(spec[at + 1 .. ^1]))
  if channel != 0:
    stdout.writeLine("probe: " & probe(channel))
  stdout.flushFile()
  lib.destroy(ctx)
  stdout.writeLine("destroyed")
  stdout.flushFile()
  quit(0)

if existsEnv(leftoverChildVar):
  # Before any library is built: the child only loads the one it is given.
  leftoverChild(getEnv(leftoverChildVar))

let
  meter = build("meter_impl.nim", "kitmeter", "meter_module")
  sensor = build("sensor_impl.nim", "kitsensor", "sensor_module")
  shapes = build("shapes_impl.nim", "kitshapes", "shapes_module")
  tuner = build("tuner_impl.nim", "kittuner", "tuner_module")
  tunerApply =
    cast[ApplyFn](tuner.handle.symAddr("logos_tuner_module_MODULE_apply_configuration"))

when defined(posix):
  import std/posix

  proc sigactionOf(
    sig: cint, act, old: ptr Sigaction
  ): cint {.importc: "sigaction", header: "<signal.h>".}

  proc sentinel(sig: cint) {.noconv.} =
    discard

let
  ledgerPath = buildKitLibrary("ledger_lib.nim", "kitledger", exports = "ledger_module")
  ledgerLenientPath = buildKitLibrary(
    "ledger_lib.nim",
    "kitledgerp",
    exports = "ledger_module",
    strictDestroy = false,
    reason = "the production line of G438's leftover cases",
  ) ## [DECISIONS G438] the same kit as a library that is not strict about destroy

let (ledger, pipeAfterLoad) = block:
  ## [DECISIONS G340, P5] The confined ledger kit, whose main module imports
  ## chronos before the kit (`ledger_lib.nim`), loaded with a sentinel
  ## `SIGPIPE` handler; what is set after the load is kept for the test below,
  ## then this program's own handler goes back.
  let path = ledgerPath
  when defined(posix):
    var mark, own, now: Sigaction
    mark.sa_handler = sentinel
    discard sigemptyset(mark.sa_mask)
    doAssert sigactionOf(SIGPIPE, addr mark, addr own) == 0
    let lib = load(path, "ledger_module")
    doAssert sigactionOf(SIGPIPE, addr own, addr now) == 0
    (lib, cast[pointer](now.sa_handler))
  else:
    (load(path, "ledger_module"), pointer(nil))

let sensorConfined = block:
  ## [DECISIONS G338] The §3.9.2 sensor as a confined kit with
  ## `_MODULE_async_api` (`sensor_confined_impl.nim`), linked with that kit's
  ## export list (`sdk/tests/generated/confined/`).
  var tree = kitTree()
  tree.generated = @[repoDir / sdkGeneratedDir / "confined"]
  load(
    buildKitLibraryIn(
      tree, "sensor_confined_impl.nim", "kitsensorc", exports = "sensor_module"
    ),
    "sensor_module",
  )

let ledgerOther = load(
  ## [DECISIONS G342] The same confined kit built with the other memory manager
  ## (refc beside this orc build, orc beside a refc one).
  buildKitLibrary("ledger_lib.nim", "kitledgerx", otherMm, exports = "ledger_module"),
  "ledger_module",
)

let metricsOnly =
  build("metrics_only_impl.nim", "kitmetricsonly", "metrics_only_module")
  ## [DECISIONS G339] The interface-only kit (`sdk/tests/kit/`): the §3.9.2
  ## `metrics_provider` with no primary document.

let idleLib = block:
  ## [DECISIONS G339] A kit with lifecycle symbols and no contract, linked with
  ## its export list.
  let h = loadLib(buildKitLibrary("idle_impl.nim", "kitidle", exports = "idle_module"))
  doAssert h != nil, "dlopen failed: kitidle"
  h

var otherPublished: Atomic[int]

proc countPublish(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): CErrorCode {.cdecl, gcsafe, raises: [].} =
  ## The host's publish callback for `ledgerOther`: it runs on the library's
  ## publisher thread, which this program's runtime has never seen, so it only
  ## counts.
  otherPublished += 1
  CErrorCode(0)

type OtherPoster = object ## One thread's posts to `ledgerOther`.
  dispatch: DispatchFn
  free: FreeFn
  ctx: ptr LogosModuleContext
  index: int
  ok: Atomic[int] ## posts whose total and thread were as expected
  thread: Atomic[uint64] ## the module thread its first answer named

proc otherPosts(p: ptr OtherPoster) {.thread.} =
  let key = "t" & $p.index
  for i in 1 .. 20:
    let c = call(
      p.dispatch,
      p.free,
      p.ctx,
      "post",
      encode(LedgerPostRequest(key: key, amount: 1)).get,
    )
    if c.code == ecOk:
      let r = LedgerPostResponse.decode(c.response)
      if r.isOk and r.get.total == uint64(i):
        if p.thread.load == 0:
          p.thread.store(r.get.thread)
        if p.thread.load == r.get.thread and r.get.thread != uint64(getThreadId()):
          p.ok += 1
  releasePerThread()

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

let typedConfined = ThFns(
  sensorConfigure:
    sensorConfined.typedSymbol("logos_sensor_module_CALL_sensor_NS_control_Configure"),
  sensorSnapshot:
    sensorConfined.typedSymbol("logos_sensor_module_CALL_metrics_provider_Snapshot"),
)

proc asyncApiOf(lib: Library, module: string): ptr LogosAsyncProviderApi =
  ## [SPEC INTERFACE §2.9.2] What the library's `_MODULE_async_api` returns.
  let p = lib.handle.symAddr(cstring("logos_" & module & "_MODULE_async_api"))
  doAssert p != nil, "missing symbol " & module & " async_api"
  cast[ModuleAsyncApiFn](p)()

let helpers = block:
  ## The call helpers the helper library exports, in the harness's slots.
  let lib = loadLib(buildKitLibrary("calls_lib.nim", "kitcalls"))
  doAssert lib != nil, "dlopen failed: kitcalls"
  proc helper(name: string): pointer =
    result = lib.symAddr(cstring(name))
    doAssert result != nil, "missing symbol " & name

  throughHelpers(
    ThHelpers(
      meterRead: helper("lcn_invoke_meter_Read"),
      sensorConfigure: helper("lcn_invoke_sensor_NS_control_Configure"),
      sensorSnapshot: helper("lcn_invoke_metrics_provider_Snapshot"),
      shapesReflect: helper("lcn_invoke_shapes_Reflect"),
      shapesPick: helper("lcn_invoke_shapes_Pick"),
      shapesPing: helper("lcn_invoke_shapes_Ping"),
      meterReadClear: helper("lcn_clear_meter_Read"),
      sensorConfigureClear: helper("lcn_clear_sensor_NS_control_Configure"),
      sensorSnapshotClear: helper("lcn_clear_metrics_provider_Snapshot"),
      shapesReflectClear: helper("lcn_clear_shapes_Reflect"),
      shapesPickClear: helper("lcn_clear_shapes_Pick"),
      shapesPingClear: helper("lcn_clear_shapes_Ping"),
    )
  )

{.compile: "support/procstats.c".}
proc threadCount(): clong {.importc: "lcn_thread_count", cdecl.}
proc residentBytes(): clong {.importc: "lcn_resident_bytes", cdecl.}

proc steadyThreads(): int =
  ## The thread count once two reads 20 ms apart agree: on macOS a thread just
  ## joined can stay listed for a moment.
  result = int(threadCount())
  for _ in 0 ..< 100:
    sleep(20)
    let n = int(threadCount())
    if n == result:
      return
    result = n

proc threadsBackTo(target: int): int =
  ## The thread count once it is back to `target`, or after 5 s.
  result = int(threadCount())
  for _ in 0 ..< 250:
    if result == target:
      return
    sleep(20)
    result = int(threadCount())

proc openDescriptors(): int =
  when defined(linux):
    for _ in walkDir("/proc/self/fd"):
      inc result
  else:
    for _ in walkDir("/dev/fd"):
      inc result

proc leftoverRun(path: string, channel: int): tuple[output: string, code: int] =
  ## [DECISIONS G438] The leftover cases' child on the library at `path`.
  putEnv(leftoverChildVar, path & "|" & $channel)
  try:
    let (output, code) = execCmdEx(quoteShell(getAppFilename()))
    result = (output, code)
  finally:
    delEnv(leftoverChildVar)

const leftLine = "logos module kit (confined): ledger_module: destroy left "

proc routeTo(lib: Library, ctx: ptr LogosModuleContext): ptr TestRoute =
  ## A route bound directly to a module library's instance.
  newRoute(rmDirect, ctx, lib.dispatch, lib.free)

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

proc now(ctx: ptr LogosModuleContext): RadioNowResponse =
  let c = call(tuner.dispatch, tuner.free, ctx, "now", encode(RadioNowRequest()).get)
  doAssert c.status.isOk
  RadioNowResponse.decode(c.response).get

proc applied(ctx: ptr LogosModuleContext, input: seq[byte]): AbiCheck =
  readStatus(
    tunerApply(
      ctx, cast[ptr UncheckedArray[uint8]](unsafeAddr input[0]), csize_t(input.len)
    )
  )

suite "ifc.kit: kit modules as shared libraries (INTERFACE §2.6, §2.8) [IMPL]":
  test "[CFG-0068] [CFG-0070] [CFG-0096] [CFG-0097] a configured, live kit library: init with the typed value, apply, and an input for another schema":
    check tunerApply != nil
    let config = tunerInput(tunerValue("dyn", 2), 5)
    var i = input(configuration = config)
    var ctx: ptr LogosModuleContext
    check checkOutcome(tuner.init(addr i, addr ctx), contextShape(ctx)).isOk
    var n = ctx.now
    check n.station == "dyn" and n.volume == 2 and n.revision == 5 and n.applied == 0
    check ctx.applied(tunerInput(tunerValue("dyn-2", 3), 6)).isOk
    n = ctx.now
    check n.station == "dyn-2" and n.volume == 3 and n.applied == 1
    var other = tunerCommitment()
    other.schema_root[0] = other.schema_root[0] xor 1
    let foreign = encode(
      LogosNSModuleConfigurationConfigurationInput(
        schema_commitment: other, value: tunerValue("x"), value_revision: 7
      )
    ).tryGet
    let refused = ctx.applied(foreign)
    check refused.isErr and refused.error.code == ecVersionMismatch
    check ctx.now.station == "dyn-2"
    tuner.destroy(ctx)
    var bare = input()
    let st = checkOutcome(tuner.init(addr bare, addr ctx), contextShape(ctx))
    check st.isErr and st.error.code == ecInvalidParams and ctx == nil

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

  test "[DECISIONS G341] a library linked with its kit's export list exports its ABI and nothing else":
    for (lib, name, module, dir) in [
      (meter, "kitmeter", "meter_module", generatedDir),
      (sensor, "kitsensor", "sensor_module", generatedDir),
      (shapes, "kitshapes", "shapes_module", generatedDir),
      (tuner, "kittuner", "tuner_module", generatedDir),
      (sensorConfined, "kitsensorc", "sensor_module", sdkGeneratedDir / "confined"),
      (ledger, "kitledger", "ledger_module", generatedDir),
      (metricsOnly, "kitmetricsonly", "metrics_only_module", sdkGeneratedDir),
    ]:
      checkpoint name
      var listed = 0
      for line in lines(repoDir / dir / module & "_kit.exports"):
        if line.len > 0 and line[0] == '_':
          checkpoint line
          check lib.handle.symAddr(cstring(line[1 ..^ 1])) != nil
          inc listed
      check listed >= 7 # name, init, destroy, call_surface, free, dispatch, a _CALL_
      when not defined(windows):
        # What the list leaves out: the library's `NimMain` and the BLAKE3
        # functions its C marks for export (base/libvisibility).
        for hidden in ["lib" & name & "NimMain", "blake3_hasher_init", "blake3_version"]:
          checkpoint hidden
          check lib.handle.symAddr(cstring(hidden)) == nil

  test "[IMPL-DECISION G339] [IFC-0880] an interface-only kit library: its descriptor, and its interface's method by dispatch and by typed function":
    check $metricsOnly.name() == "metrics_only_module"
    var n: csize_t
    let p = metricsOnly.callSurface(addr n)
    let bytes = @(cast[ptr UncheckedArray[uint8]](p).toOpenArray(0, int(n) - 1))
    let b = acceptBinding(
      "metrics_only_module", Opt.none(string), [mirror("IFC/3.9.2.interface.cddl")]
    ).get
    check bytes == callSurfaceDescriptor(b).get
    check acceptCallSurfaceDescriptor(bytes, "metrics_only_module").get.primary.isNone
    let ctx = metricsOnly.start(publish = false)
    let c = call(metricsOnly.dispatch, metricsOnly.free, ctx, "snapshot", diag("{}"))
    check c.status.isOk and c.response == diag("{\"count\": 1}")
    let snap = cast[SnapshotFn](metricsOnly.handle.symAddr(
      "logos_metrics_only_module_CALL_metrics_provider_Snapshot"
    ))
    check snap != nil
    var owner: LogosResponseOwner
    var count: uint64
    check readStatus(snap(ctx, addr owner, addr count)).isOk and count == 2
    if not owner.release.isNil:
      owner.release(owner.state)
    check call(metricsOnly.dispatch, metricsOnly.free, ctx, "configure", diag("{}")).code ==
      ecMethodNotFound
    metricsOnly.destroy(ctx)

  test "[IMPL-DECISION G339] [IFC-0880] [IFC-0881] a kit library with lifecycle symbols and no contract exports no provider symbol":
    for suffix in ["name", "init", "destroy"]:
      check idleLib.symAddr(cstring("logos_idle_module_MODULE_" & suffix)) != nil
    for suffix in ["call_surface", "free", "dispatch", "async_api"]:
      check idleLib.symAddr(cstring("logos_idle_module_MODULE_" & suffix)) == nil
    let name = cast[NameFn](idleLib.symAddr("logos_idle_module_MODULE_name"))
    check $name() == "idle_module"
    let init = cast[InitFn](idleLib.symAddr("logos_idle_module_MODULE_init"))
    let destroy = cast[DestroyFn](idleLib.symAddr("logos_idle_module_MODULE_destroy"))
    var i = input(publish = false)
    var ctx: ptr LogosModuleContext
    check checkOutcome(init(addr i, addr ctx), contextShape(ctx)).isOk
    destroy(ctx)
    var listed = 0
    for line in lines(repoDir / sdkGeneratedDir / "idle_module_kit.exports"):
      if line.len > 0 and line[0] == '_':
        inc listed
    check listed == 3

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

  test "[IFC-0164] [IFC-0162] [IFC-0202] typed provider functions through the libraries' exports":
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

  test "[IFC-0927] a typed call at the payload depth limit on a thread with 512 KiB of stack [IMPL]":
    let ctx = shapes.start(publish = false)
    let deepest = typedReflectOnStack(typed, ctx, rvDeepest, 512 * 1024)
    check deepest.status.isOk and deepest.same
    let tooDeep = typedReflectOnStack(typed, ctx, rvTooDeep, 512 * 1024)
    check tooDeep.code == ecInvalidParams and tooDeep.untouched
    shapes.destroy(ctx)

  test "[IFC-0699] [IFC-0702] [IFC-0706] typed call helpers from a library of their own, through routes into the module libraries":
    let m = meter.start()
    let rm = meter.routeTo(m)
    let r4 = typedRead(helpers, rm.asModule, 4)
    check r4.status.isOk and r4.owned
    check r4.text == "label=\"ch4\" reading=(absent,40)"
    let r13 = typedRead(helpers, rm.asModule, 13)
    check r13.code == ecModule and r13.untouched
    check r13.message == "channel 13 is broken"
    let cleared = typedClear(helpers, rm.asModule, ccRead)
    check cleared.status.isOk and cleared.untouched and cleared.same
    check not rm.outstanding and rm.counts == (3, 2, 0)
    rm.dispose()
    meter.destroy(m)
    let s = sensor.start(publish = false)
    let rs = sensor.routeTo(s)
    check typedConfigure(helpers, rs.asModule, "sensor", 3).status.isOk
    check typedSnapshot(helpers, rs.asModule).text == "count=1"
    rs.dispose()
    sensor.destroy(s)
    let sh = shapes.start(publish = false)
    let r = shapes.routeTo(sh)
    for v in [rvFull, rvAbsent, rvEmpty, rvNumbers, rvDeep]:
      let t = typedReflect(helpers, r.asModule, v)
      checkpoint $v & ": " & t.message
      check t.status.isOk and t.same
    for v in [rvNullText, rvBadKind, rvCycle, rvNullRecursive, rvTooDeep, rvBadUtf8]:
      let t = typedReflect(helpers, r.asModule, v)
      checkpoint $v & ": " & t.message
      check t.code == ecInvalidParams and t.untouched
    check typedPick(helpers, r.asModule, pvName).text ==
      "found=true entry=dir{kind=\"dir\" path=\"/nm\" entries=[\"nm\",\"nm\"]}"
    check typedPing(helpers, r.asModule).status.isOk
    check typedReflectCleared(helpers, r.asModule).same
    for which in [ccReflect, ccPick, ccPing]:
      let t = typedClear(helpers, r.asModule, which)
      checkpoint $which & ": " & t.message
      check t.status.isOk and t.untouched and t.same and not t.owned
    let (calls, releases, mismatches) = r.counts
    check calls == releases and mismatches == 0 and not r.outstanding
    r.dispose()
    shapes.destroy(sh)

  test "[IFC-0265] [IFC-0702] [IFC-0706] call helpers from threads none of the three runtimes has seen; owners cleared on others":
    const
      workers = 4
      rounds = 40
    var failures: Atomic[int]
    var held: array[workers * rounds, LogosResponseOwner]

    proc caller(
        args: (ptr TestRoute, ptr Atomic[int], ptr LogosResponseOwner, int)
    ) {.thread.} =
      let (route, failures, owners, id) = args
      let owned = cast[ptr UncheckedArray[LogosResponseOwner]](owners)
      for k in 0 ..< rounds:
        let t = typedReflect(helpers, route.asModule, rvFull, keep = true)
        if not (t.status.isOk and t.same and t.owned):
          failures[] += 1
        owned[id * rounds + k] = t.owner
        let c = typedClear(helpers, route.asModule, ccPick)
        if not (c.status.isOk and c.untouched and c.same):
          failures[] += 1
        let bad = typedReflect(helpers, route.asModule, rvBadUtf8)
        if bad.code != ecInvalidParams or not bad.untouched:
          failures[] += 1

    proc clearer(args: (ptr LogosResponseOwner, int)) {.thread.} =
      let owned = cast[ptr UncheckedArray[LogosResponseOwner]](args[0])
      for k in 0 ..< rounds:
        clear(owned[args[1] * rounds + k])

    let ctx = shapes.start(publish = false)
    var routes: array[workers, ptr TestRoute] # one per caller (§2.8)
    var threads: array[
      workers, Thread[(ptr TestRoute, ptr Atomic[int], ptr LogosResponseOwner, int)]
    ]
    for i in 0 ..< workers:
      routes[i] = shapes.routeTo(ctx)
      createThread(threads[i], caller, (routes[i], addr failures, addr held[0], i))
    joinThreads(threads)
    check failures.load == 0
    var clearers: array[workers, Thread[(ptr LogosResponseOwner, int)]]
    for i in 0 ..< workers:
      # each clears another caller's owners
      createThread(clearers[i], clearer, (addr held[0], (i + 1) mod workers))
    joinThreads(clearers)
    for o in held:
      check ownerEmpty(o)
    for r in routes:
      check r.counts == (2 * rounds, 2 * rounds, 0) and not r.outstanding
      r.dispose()
    shapes.destroy(ctx)

suite "ifc.kit: a thread-confined kit as a shared library (DECISIONS G335, G338, G340) [IMPL]":
  test "[IFC-0748] [IFC-0749] [IFC-0751] [IFC-0743] a confined kit's typed, dispatch and deferred surfaces give one answer, the implemented interface's method included":
    let api = sensorConfined.asyncApiOf("sensor_module")
    check checkAsyncProviderApi(api).isOk
    check api == sensorConfined.asyncApiOf("sensor_module")
    let s = sensorConfined.start(publish = false)
    proc configure(limit: uint64): seq[byte] =
      encode(
        SensorNSControlConfigureRequest(settings: SensorNSControlSettings(limit: limit))
      ).get

    let snapshotRequest = encode(MetricsProviderSnapshotRequest()).get
    proc deferred(i: int, bare: string, params: seq[byte]): ptr FakeInvocation =
      result = prepareFake(i, bare, params)
      submit(api, s, result)
      doAssert result.settledIn()

    # A success of each surface; the snapshot then counts all three.
    check typedConfigure(typedConfined, s, "sensor", 3).status.isOk
    let viaDispatch =
      call(sensorConfined.dispatch, sensorConfined.free, s, "configure", configure(4))
    check viaDispatch.status.isOk
    let viaSubmit = deferred(0, "configure", configure(5))
    check same(viaSubmit.status, viaDispatch.status)
    check viaSubmit.responseOf == viaDispatch.response
    check viaSubmit.exactlyOnce
    clearFake(viaSubmit)
    check typedSnapshot(typedConfined, s).text == "count=3"
    let snap =
      call(sensorConfined.dispatch, sensorConfined.free, s, "snapshot", snapshotRequest)
    check MetricsProviderSnapshotResponse.decode(snap.response).get.count == 3
    let snapSubmit = deferred(1, "snapshot", snapshotRequest)
    check snapSubmit.status.isOk
    check snapSubmit.responseOf == snap.response
    clearFake(snapSubmit)
    # A handler's failure: one code and one message on all three.
    let typedFail = typedConfigure(typedConfined, s, "sensor", 13)
    check typedFail.status.error.code == ecModule
    check typedFail.untouched
    let dispatchFail =
      call(sensorConfined.dispatch, sensorConfined.free, s, "configure", configure(13))
    check same(dispatchFail.status, typedFail.status)
    let submitFail = deferred(2, "configure", configure(13))
    check same(submitFail.status, typedFail.status)
    check submitFail.message == "limit 13 is refused"
    clearFake(submitFail)
    # The kit's own refusals: an unknown method, a request off its schema.
    for (i, bare, params) in [
      (3, "nosuch", snapshotRequest),
      (4, "configure", diag("{\"settings\": {\"kind\": \"sensor\", \"limit\": \"x\"}}")),
      (5, "snapshot", diag("{\"extra\": 1}")),
    ]:
      checkpoint bare
      let d = call(sensorConfined.dispatch, sensorConfined.free, s, bare, params)
      check d.status.isErr
      let fi = deferred(i, bare, params)
      check same(fi.status, d.status)
      check fi.exactlyOnce
      clearFake(fi)
    check typedSnapshot(typedConfined, s).text == "count=3"
    sensorConfined.destroy(s)

  test "[IMPL-DECISION G340] a confined kit whose main module imports chronos first leaves the host's SIGPIPE as it was":
    when defined(posix):
      check pipeAfterLoad == cast[pointer](sentinel)
    else:
      skip()

  test "[IMPL-DECISION G335] the library's own runtime runs the instance on its module thread":
    var inp = input()
    var ctx: ptr LogosModuleContext
    check ledger.init(addr inp, addr ctx).code == CErrorCode(0)
    let c = call(
      ledger.dispatch,
      ledger.free,
      ctx,
      "probe",
      encode(LedgerProbeRequest(channel: 1, value: 0)).get,
    )
    check c.code == ecOk
    let r = LedgerProbeResponse.decode(c.response).get
    check r.thread != uint64(getThreadId())
    check r.note == $ecNotReady # no invocation context is current here
    ledger.destroy(ctx)

  test "[IMPL-DECISION G342] [IMPL-DECISION G335] the confined kit built with the other memory manager: 8 threads post at once, its GC'd table stays on its module thread, and every event its kit did not refuse reaches the host's callback by destroy":
    # [DECISIONS G342] A refc library is built without the sanitizer.
    if defined(msan) and otherMm == "refc":
      skip()
      break
    otherPublished.store(0)
    var inp = input()
    inp.publish = countPublish
    inp.publishUserData = nil
    var ctx: ptr LogosModuleContext
    check ledgerOther.init(addr inp, addr ctx).code == CErrorCode(0)
    var posters: array[8, OtherPoster]
    var threads: array[8, Thread[ptr OtherPoster]]
    for i in 0 ..< posters.len:
      posters[i].dispatch = ledgerOther.dispatch
      posters[i].free = ledgerOther.free
      posters[i].ctx = ctx
      posters[i].index = i
      createThread(threads[i], otherPosts, addr posters[i])
    joinThreads(threads)
    for i in 0 ..< posters.len:
      check posters[i].ok.load == 20
      check posters[i].thread.load == posters[0].thread.load
    let c = call(
      ledgerOther.dispatch,
      ledgerOther.free,
      ctx,
      "probe",
      encode(LedgerProbeRequest(channel: 22, value: 0)).get,
    )
    check c.code == ecOk
    let note = LedgerProbeResponse.decode(c.response).get.note
    check note.startsWith("0 0 ")
    let refused = parseInt(note[4 .. ^1])
    ledgerOther.destroy(ctx) # delivers what is queued
    check otherPublished.load + refused == posters.len * 20

suite "ifc.kit: what a confined kit's destroy leaves registered (DECISIONS G438) [IMPL]":
  test "[IMPL-DECISION G438] a pipe end the module left registered: the lenient library writes one line naming it and returns; the strict one aborts with that line":
    when not defined(posix):
      skip()
    else:
      let (lenient, lenientCode) = leftoverRun(ledgerLenientPath, 25)
      checkpoint lenient
      check lenientCode == 0
      check "probe: registered" in lenient
      check (leftLine & "at least 1 descriptor registered") in lenient
      check lenient.count(leftLine) == 1
      check "destroyed" in lenient
      let (strict, strictCode) = leftoverRun(ledgerPath, 25)
      checkpoint strict
      check strictCode != 0
      check (leftLine & "at least 1 descriptor registered") in strict
      check "destroyed" notin strict

  test "[IMPL-DECISION G438] a pipe end closed while still registered: only the main line's selector sees it; 4.4.1 writes nothing":
    when not defined(posix):
      skip()
    else:
      let (lenient, lenientCode) = leftoverRun(ledgerLenientPath, 26)
      checkpoint lenient
      let (strict, strictCode) = leftoverRun(ledgerPath, 26)
      checkpoint strict
      check lenientCode == 0
      check "probe: registered" in lenient
      check "destroyed" in lenient
      if "chronos: main line" in lenient:
        check (leftLine & "other registrations") in lenient
        check strictCode != 0
        check (leftLine & "other registrations") in strict
        check "destroyed" notin strict
      else:
        check "chronos: 4.4.1" in lenient
        check leftLine notin lenient # what 4.4.1 cannot see (G438)
        check strictCode == 0
        check leftLine notin strict
        check "destroyed" in strict

  test "[IMPL-DECISION G438] a clean destroy writes no line, lenient or strict":
    when not defined(posix):
      skip()
    else:
      for path in [ledgerLenientPath, ledgerPath]:
        let (output, code) = leftoverRun(path, 0)
        checkpoint output
        check code == 0
        check "destroyed" in output
        check "logos module kit" notin output

  test "[IMPL-DECISION G438] [IMPL-DECISION G439] 200 init and destroy cycles of the confined library: descriptors, threads and resident memory back to the baseline":
    when not defined(posix):
      skip()
    else:
      proc cycle() =
        var inp = input()
        inp.publish = countPublish # on the library's publisher thread: it only counts
        inp.publishUserData = nil
        var ctx: ptr LogosModuleContext
        doAssert ledger.init(addr inp, addr ctx).code == CErrorCode(0)
        let c = call(
          ledger.dispatch,
          ledger.free,
          ctx,
          "post",
          encode(LedgerPostRequest(key: "cycle", amount: 1)).get,
        )
        doAssert c.code == ecOk
        ledger.destroy(ctx)

      for _ in 0 ..< 10:
        cycle()
      let fds = openDescriptors()
      let threads = steadyThreads()
      let resident = residentBytes()
      for _ in 0 ..< 200:
        cycle()
      let grown = residentBytes() - resident
      echo "    200 cycles: resident memory grew by ", grown div 1024, " KiB"
      check openDescriptors() == fds
      let after = threadsBackTo(threads)
      if after != threads:
        echo "    threads: ",
          threads, " after the warm-up, ", after, " after 200 cycles"
      check threads > 0 and after == threads
      # DECISIONS G438: under 1 MiB (Mac 2026-11-21: 16 KiB orc, 0 refc, 16 KiB
      # orc-release); resident memory rarely returns to the byte.
      check resident > 0 and grown < 1024 * 1024
