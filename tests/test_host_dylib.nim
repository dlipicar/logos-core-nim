## The Host Embedding API as a C library (RUNTIME §13): `liblogos_runtime`
## built with `--app:lib` under this build's memory manager, mode and
## sanitizer, loaded with `dlopen` and driven from C (`host/host_harness.c`),
## from threads no Nim runtime started.
##
## The deployment has three kinds of module code, each on a Nim runtime of its
## own or none: a C module linked into this test and registered as a true
## static binding (`host/test_orchestrator.c`); the meter kit library,
## registered statically with the addresses `dlsym` finds; and the sensor kit
## library as a `direct_dynamic` record the Runtime verifies and loads.
## `host/embed_main.c` is a program that includes only `logos_runtime.h` and
## links against the library.

import std/[monotimes, os, osproc, strutils, times]
import unittest2
import ../src/logos_core/abi/host
import ../src/logos_core/crypto/blake3
import ../src/logos_core/iface/outcome
import ../src/logos_core/runtime/[host_config_types, store_types]
import ./support/[hostbuild, kitbuild, tunerconfig]

{.compile: "host/host_harness.c".}
{.compile: "host/test_orchestrator.c".}

type
  HhResult {.bycopy.} = object ## `hh_result_t`
    code: int32
    hasMessage: int32
    message: array[513, char]
    detailLen: csize_t
    detail: array[4096, uint8]

  WaitFn = pointer

const
  TorPlain = 0'i32
  TorShutdown = 1'i32
  TorWaitProbe = 2'i32
  TorAutostart = 3'i32

proc hhLoad(path: cstring): cint {.importc: "hh_load", cdecl.}
proc hhWaitFunction(): WaitFn {.importc: "hh_wait_function", cdecl.}
proc hhCreate(
  abiVersion: uint32,
  format: cstring,
  bytes: ptr uint8,
  len: csize_t,
  rt: ptr ptr LogosRuntimeHandle,
  r: var HhResult,
) {.importc: "hh_create", cdecl.}

proc hhRegisterOrchestrator(
  rt: ptr LogosRuntimeHandle, binding: cstring, r: var HhResult
) {.importc: "hh_register_orchestrator", cdecl.}

proc hhRegisterLibrary(
  rt: ptr LogosRuntimeHandle,
  binding, path: cstring,
  names: ptr cstring,
  n: csize_t,
  r: var HhResult,
): csize_t {.importc: "hh_register_library", cdecl.}

proc hhStart(rt: ptr LogosRuntimeHandle, r: var HhResult) {.importc: "hh_start", cdecl.}
proc hhRequestShutdown(
  rt: ptr LogosRuntimeHandle, r: var HhResult
) {.importc: "hh_request_shutdown", cdecl.}

proc hhWaitForShutdown(
  rt: ptr LogosRuntimeHandle, r: var HhResult
) {.importc: "hh_wait_for_shutdown", cdecl.}

proc hhDestroy(
  rt: ptr LogosRuntimeHandle, r: var HhResult
) {.importc: "hh_destroy", cdecl.}

proc hhWaitBegin(rt: ptr LogosRuntimeHandle): cint {.importc: "hh_wait_begin", cdecl.}
proc hhWaitFinished(): cint {.importc: "hh_wait_finished", cdecl.}
proc hhWaitEnd(r: var HhResult) {.importc: "hh_wait_end", cdecl.}
proc hhDiagnosticsCheck(): cint {.importc: "hh_diagnostics_check", cdecl.}

proc torReset(mode: int32) {.importc: "tor_reset", cdecl.}
proc torSetWait(
  wait: WaitFn, rt: ptr LogosRuntimeHandle
) {.importc: "tor_set_wait", cdecl.}

proc torSetDestroyGate(closed: cint) {.importc: "tor_set_destroy_gate", cdecl.}
proc torInitResult(): cint {.importc: "tor_init_result", cdecl.}
proc torInitsSeen(): cint {.importc: "tor_inits_seen", cdecl.}
proc torDestroysSeen(): cint {.importc: "tor_destroys_seen", cdecl.}
proc torAutostartDone(): cint {.importc: "tor_autostart_done", cdecl.}
proc torStartedCode(i: cint): cint {.importc: "tor_started_code", cdecl.}
proc torShutdownRuntime(): cint {.importc: "tor_shutdown_runtime", cdecl.}

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "host-dylib" / kitVariant
  library = buildRuntimeLibrary()
  meterLib = buildKitLibrary("meter_impl.nim", "hdmeter")
  sensorLib = buildKitLibrary("sensor_impl.nim", "hdsensor")
  tunerLib = buildKitLibrary("tuner_impl.nim", "hdtuner")
removeDir(work)
createDir(work)
doAssert hhLoad(cstring(library)) == 0, "cannot load " & library

const meterSymbols = block:
  ## Every symbol the meter kit library exports, as its generated kit names them.
  var names: seq[string]
  let kit = staticRead("generated/meter_module_kit.nim")
  var at = 0
  while true:
    let i = kit.find("exportc: \"", at)
    if i < 0:
      break
    let start = i + "exportc: \"".len
    let stop = kit.find('"', start)
    names.add(kit[start ..< stop])
    at = stop
  names

proc ec(r: HhResult): ErrorCode =
  errorCode(int64(r.code)).get

proc text(r: HhResult): string =
  $cast[cstring](unsafeAddr r.message[0])

proc digestOfFile(path: string): seq[byte] =
  var h: Blake3Hasher
  h.init()
  let bytes = readFile(path)
  h.update(bytes.toOpenArrayByte(0, bytes.high))
  @(h.finish())

proc module(instance, module, binding: string): LcnAppModule =
  LcnAppModule(
    instance: instance,
    module: module,
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_static,
      arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
    ),
  )

proc sensor(): LcnAppModule =
  LcnAppModule(
    instance: "sensor-1",
    module: "sensor_module",
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_dynamic,
      arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(
        artifact: LcnAppArtifact(
          id: "sensor", local_path: sensorLib, hash: digestOfFile(sensorLib)
        )
      ),
    ),
  )

proc tunerModule(provisioned: Opt[seq[byte]]): LcnAppModule =
  ## The configured tuner kit library as a `direct_dynamic` record.
  LcnAppModule(
    instance: "tuner-1",
    module: "tuner_module",
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_dynamic,
      arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(
        artifact: LcnAppArtifact(
          id: "tuner", local_path: tunerLib, hash: digestOfFile(tunerLib)
        )
      ),
    ),
    configuration: Opt.some(tunerDeclBytes(live = true)),
    provisioned_configuration: provisioned,
  )

var handles = 0

proc deployment(): LcnAppConfig =
  inc handles
  LcnAppConfig(
    runtime: LcnAppRuntime(work_dir: work / ("h" & $handles)),
    policy: LcnAppPolicy(),
    orchestration: "orch",
    modules: @[
      module("orch", "test_orchestrator", "orchestrator"),
      module("meter-1", "meter_module", "meter"),
      sensor(),
    ],
  )

proc create(
    c: LcnAppConfig, abiVersion = RuntimeHostAbiVersion
): (ptr LogosRuntimeHandle, HhResult) =
  var bytes = c.encode.get
  hhCreate(
    abiVersion,
    AppConfigFormat,
    addr bytes[0],
    csize_t(bytes.len),
    addr result[0],
    result[1],
  )

proc registered(c: LcnAppConfig): ptr LogosRuntimeHandle =
  ## A handle for `c` with the C orchestrator and the meter library registered.
  var r: HhResult
  let (rt, created) = create(c)
  check created.ec == ecOk
  hhRegisterOrchestrator(rt, "orchestrator", r)
  check r.ec == ecOk
  var names: seq[cstring]
  for n in meterSymbols:
    names.add(cstring(n))
  check hhRegisterLibrary(
    rt, "meter", cstring(meterLib), addr names[0], csize_t(names.len), r
  ) == 0
  check r.ec == ecOk
  rt

proc call(
    f: proc(rt: ptr LogosRuntimeHandle, r: var HhResult) {.cdecl.},
    rt: ptr LogosRuntimeHandle,
): HhResult =
  f(rt, result)

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 30): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc finish(rt: ptr LogosRuntimeHandle) =
  torSetDestroyGate(0)
  check call(hhRequestShutdown, rt).ec == ecOk
  check call(hhWaitForShutdown, rt).ec == ecOk
  check call(hhDestroy, rt).ec == ecOk

suite "run.host-dylib: liblogos_runtime from C (RUNTIME §13)":
  setup:
    torReset(TorPlain)

  test "[RUN-0716] [RUN-0739] a program that includes only logos_runtime.h builds against the library and runs":
    let program = buildEmbedMain(library)
    var c = deployment()
    c.modules = @[sensor()]
    c.orchestration = "sensor-1" # the role follows the instance, any module
    let path = work / "embed.cbor"
    let bytes = c.encode.get
    writeFile(path, cast[string](bytes))
    let (output, code) = execCmdEx(quoteShellCommand([program, path]))
    checkpoint "embed_main exited with " & $code & ", output: " & output.escape
    check code == 0 and output.strip == "ok"

  test "[RUN-0631] [RUN-0632] [RUN-0927] [IMPL-DECISION G193] a Runtime that ends without shutdown leaves a whole store, and the next start resumes from it":
    let program = buildEmbedMain(library)
    var c = deployment()
    c.modules = @[sensor()]
    c.orchestration = "sensor-1"
    let base = work / "crash"
    c.runtime.store_dir = Opt.some(base / "store")
    c.runtime.state_root = Opt.some(base / "state")
    let path = work / "crash.cbor"
    writeFile(path, cast[string](c.encode.get))
    let (output, code) = execCmdEx(quoteShellCommand([program, path, "crash"]))
    checkpoint "embed_main exited with " & $code & ", output: " & output.escape
    check code == 3
    proc stored(): LcnRsInstance =
      let text = readFile(base / "store" / "runtime-state.cbor")
      let s = LcnRsState.decode(text.toOpenArrayByte(0, text.high)).tryGet
      check s.instances.len == 1
      s.instances[0]

    # What the child wrote before `start` returned: `ready`, never exposed
    # before its write, and the whole file.
    let crashed = stored()
    check crashed.state.kind == LcnRsInstanceStateChoiceKind.Ready
    check crashed.intent.kind == LcnRsInstanceIntentChoiceKind.Requested
    # The lock shows the child is gone; the orchestration instance's retained
    # intent is resumed from `error`/`other` through the recovery path.
    let (rt, created) = create(c)
    check created.ec == ecOk
    check call(hhStart, rt).ec == ecOk
    rt.finish()
    let after = stored()
    check after.state.kind == LcnRsInstanceStateChoiceKind.Unloaded
    check after.intent_revision == crashed.intent_revision
    check after.revision > crashed.revision
    check after.failure.isNone

  test "[RUN-0725] [RUN-0746] start to destroy: a C static binding, a library's addresses from dlsym, a direct_dynamic record; a wait on a C thread":
    torReset(TorAutostart)
    let rt = registered(deployment())
    check call(hhStart, rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        torAutostartDone() == 1
    )
    check torStartedCode(0) == ord(ecOk) # meter-1, static from dlsym
    check torStartedCode(1) == ord(ecOk) # sensor-1, direct_dynamic
    check hhWaitBegin(rt) == 0
    sleep(20)
    check hhWaitFinished() == 0 # a wait initiates nothing
    check call(hhRequestShutdown, rt).ec == ecOk
    var r: HhResult
    hhWaitEnd(r)
    check r.ec == ecOk
    check call(hhWaitForShutdown, rt).ec == ecOk
    check call(hhDestroy, rt).ec == ecOk
    check torDestroysSeen() == 1

  test "[RUN-0730] a shutdown through Runtime Control is seen by a wait on a C thread":
    let rt = registered(deployment())
    check call(hhStart, rt).ec == ecOk
    check hhWaitBegin(rt) == 0
    check torShutdownRuntime() == ord(ecOk)
    var r: HhResult
    hhWaitEnd(r)
    check r.ec == ecOk
    check call(hhDestroy, rt).ec == ecOk

  test "[CFG-0063] [CFG-0068] [G141] [IMPL-DECISION G190] a provisioned value reaches a direct_dynamic configured kit as the orchestration instance starts":
    var c = deployment()
    c.orchestration = "tuner-1"
    for (provisioned, code) in [
      (Opt.some(tunerValue("host-1")), ecOk),
      # The kit refuses this station after its checks: the value reached it.
      (Opt.some(tunerValue("broken")), ecModule),
      # No value, and the orchestration instance cannot start.
      (Opt.none(seq[byte]), ecModule),
    ]:
      c.modules = @[tunerModule(provisioned)]
      let (rt, created) = create(c)
      check created.ec == ecOk
      let r = call(hhStart, rt)
      checkpoint r.text
      check r.ec == code
      rt.finish()

  test "[RUN-0764] a result's message lives in its own C thread until that thread's next call":
    check hhDiagnosticsCheck() == 0

  test "[RUN-0719] [RUN-0741] version and configuration failures, with the library's message":
    var c = deployment()
    var (rt, r) = create(c, 2)
    check r.ec == ecVersionMismatch and rt == nil
    c.orchestration = "nobody"
    (rt, r) = create(c)
    check r.ec == ecInvalidParams and rt == nil
    check r.hasMessage == 1 and "orchestration names no instance" in r.text

  test "[RUN-0759] [RUN-0763] from its own initialization the orchestrator's shutdown cancels start, and a wait is NOT_READY":
    torReset(TorShutdown)
    var rt = registered(deployment())
    check call(hhStart, rt).ec == ecCancelled
    check call(hhWaitForShutdown, rt).ec == ecOk
    check call(hhDestroy, rt).ec == ecOk
    torReset(TorWaitProbe)
    rt = registered(deployment())
    torSetWait(hhWaitFunction(), rt)
    check call(hhStart, rt).ec == ecOk
    check torInitResult() == ord(ecNotReady)
    rt.finish()

  test "[IMPL-DECISION G60] [RUN-0733] [RUN-0734] destroy is refused while module code runs, and retried":
    var c = deployment()
    c.runtime.shutdown_grace_ms = Opt.some(100'u32)
    let rt = registered(c)
    check call(hhStart, rt).ec == ecOk
    check torInitsSeen() == 1
    torSetDestroyGate(1)
    check call(hhRequestShutdown, rt).ec == ecOk
    check call(hhWaitForShutdown, rt).ec == ecModule
    check call(hhDestroy, rt).ec == ecNotReady
    torSetDestroyGate(0)
    var destroyed = false
    for _ in 0 ..< 10_000:
      if call(hhDestroy, rt).ec == ecOk:
        destroyed = true
        break
      sleep(1)
    check destroyed
    check torDestroysSeen() == 1
