## The Host Embedding API in process (RUNTIME §13; `runtime/host.nim`): the
## `logos-core-nim.app-config.v1` configuration (G76), the §13.1 version and
## size checks, the §13.4 call order, registration, the start path to the
## orchestration instance's `ready` (G190), shutdown, waiting and destruction,
## and Runtime Control `get_readiness`.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads, unicode]
import unittest2
import ../src/logos_core/cbor
import ../src/logos_core/abi/[host, types]
import ../src/logos_core/crypto/blake3
import ../src/logos_core/iface/outcome
import
  ../src/logos_core/runtime/[engine, host, host_config, host_config_types, rc_types]
import ./support/kitbuild
import ./kit/meter_impl

let work = currentSourcePath().parentDir.parentDir / "build" / "host" / kitVariant
removeDir(work)
createDir(work)

# Configurations -------------------------------------------------------------------

proc staticModule(instance, module, binding: string): LcnAppModule =
  LcnAppModule(
    instance: instance,
    module: module,
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_static,
      arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
    ),
  )

proc baseConfig(): LcnAppConfig =
  LcnAppConfig(
    runtime: LcnAppRuntime(work_dir: work / "w"),
    policy: LcnAppPolicy(),
    orchestration: "orch",
    modules: @[
      staticModule("orch", "test_orchestrator", "orchestrator"),
      staticModule("meter-1", "meter_module", "meter"),
    ],
  )

proc parse(c: LcnAppConfig): Result[HostConfig, ConfigError] =
  ## The configuration encoded as it is, schema-valid or not.
  parseHostConfig(AppConfigFormat, encodeCbor(toCbor(c)))

proc parseValue(v: CborValue): Result[HostConfig, ConfigError] =
  parseHostConfig(AppConfigFormat, encodeCbor(v))

proc rejects(r: Result[HostConfig, ConfigError], fragment: string): bool =
  if r.isOk:
    checkpoint "accepted"
    return false
  checkpoint r.error.message
  fragment in r.error.message

proc withEntry(v: CborValue, key: string, x: CborValue): CborValue =
  ## `v` with one more map entry, keys kept in deterministic order.
  var entries = v.entries
  entries.add((cbor(key), x))
  cborMap(entries)

proc root(b: byte): SchemaCommitment =
  SchemaCommitment(schema_root: newSeqWith(32, b))

suite "run.host-config: logos-core-nim.app-config.v1 (RUNTIME §13.3; G76)":
  test "[RUN-0741] a valid configuration decodes into records, in order, with the default deadlines":
    var c = baseConfig()
    c.modules[1].primary_contract = Opt.some(root(7))
    c.ordering = Opt.some(@[LcnAppOrdering(prerequisite: "orch", dependent: "meter-1")])
    let r = parseHostConfig(AppConfigFormat, c.encode.get)
    check r.isOk
    let h = r.get
    check h.workDir == work / "w"
    check h.stateRoot.isNone
    check h.orchestration == "orch"
    check h.modules.len == 2
    check h.modules[0].instance == "orch"
    check h.modules[0].record.module == "test_orchestrator"
    check h.modules[0].record.binding == "orchestrator"
    check h.modules[1].record.primaryContract.get[0] == 7
    check h.ordering == @[("orch", "meter-1")]
    check h.startupDeadline == DefaultStartupDeadline
    check h.stopDeadline == DefaultStopDeadline
    check h.shutdownGrace == DefaultShutdownGrace

  test "[RUN-0741] an unsupported configuration format identifier is rejected":
    let bytes = baseConfig().encode.get
    for f in ["logos-core-nim.daemon-config.v1", "logos-core-nim.app-config.v2", "x"]:
      check parseHostConfig(f, bytes).rejects("unsupported configuration format")

  test "[RUN-0741] malformed and non-deterministic CBOR are rejected with their detail":
    let bad = parseHostConfig(AppConfigFormat, [0xff'u8])
    check bad.rejects("deterministic-CBOR")
    check bad.error.detail == Opt.some(invalidParamsDetail(iprMalformedCbor))
    var trailing = baseConfig().encode.get
    trailing.add(0x00)
    check parseHostConfig(AppConfigFormat, trailing).error.detail ==
      Opt.some(invalidParamsDetail(iprMalformedCbor))
    # 5 as a two-byte integer: well formed, not deterministic.
    let nd = parseHostConfig(AppConfigFormat, [0x18'u8, 0x05])
    check nd.rejects("deterministic-CBOR")
    check nd.error.detail == Opt.some(invalidParamsDetail(iprNonDeterministicCbor))
    # Schema failures carry a message only.
    check parseValue(cbor(5'u64)).error.detail.isNone

  test "[RUN-0741] unknown keys and values outside the schema are rejected":
    let v = toCbor(baseConfig())
    check parseValue(v.withEntry("zzz", cbor(1'u64))).rejects("lcn.app_config")
    var rt = toCbor(baseConfig().runtime)
    var cv = toCbor(baseConfig())
    for e in cv.entries.mitems:
      if e[0].text == "runtime":
        e[1] = rt.withEntry("zzz", cbor(true))
    check parseValue(cv).rejects("lcn.app_config")
    var c = baseConfig()
    c.modules[0].instance = ""
    check parse(c).rejects("lcn.app_config")
    c = baseConfig()
    c.modules[0].module = repeat('a', 65)
    check parse(c).rejects("lcn.app_config")

  test "[RUN-0741] present arrays are non-empty (RUNTIME §8 l.1428)":
    var c = baseConfig()
    c.modules = @[]
    check parse(c).rejects("modules is empty")
    c = baseConfig()
    c.ordering = Opt.some(newSeq[LcnAppOrdering]())
    check parse(c).rejects("ordering is present but empty")
    c = baseConfig()
    c.modules[1].implements = Opt.some(newSeq[SchemaCommitment]())
    check parse(c).rejects("implements is present but empty")
    c = baseConfig()
    c.modules[1].requires = Opt.some(newSeq[LcnAppRequirement]())
    check parse(c).rejects("requires is present but empty")
    c = baseConfig()
    c.modules[1].requested_permissions = Opt.some(newSeq[LcnAppPermission]())
    check parse(c).rejects("requested_permissions is present but empty")

  test "[S5] a policy kind other than allow-all is not supported yet":
    var cv = toCbor(baseConfig())
    for e in cv.entries.mitems:
      if e[0].text == "policy":
        e[1] = cborMap(@[(cbor("kind"), cbor("deny-all"))])
    check parseValue(cv).rejects("policy kind is not supported yet")

  test "[RUN-0784] [RUN-0785] [G53] orchestration names a listed instance outside the logos_ prefix":
    var c = baseConfig()
    c.orchestration = "nobody"
    check parse(c).rejects("orchestration names no instance")
    c = baseConfig()
    c.modules[0].module = "logos_orchestrator"
    check parse(c).rejects("reserved logos_ prefix")
    # The module name does not matter otherwise: the role follows the instance.
    c = baseConfig()
    c.orchestration = "meter-1"
    check parse(c).get.orchestration == "meter-1"

  test "records: each passes the RUNTIME §8 checks; ids and state assignments are unique":
    var c = baseConfig()
    c.modules[1].module = "Meter"
    check parse(c).rejects("module instance meter-1:")
    c = baseConfig()
    c.modules[1].instance = "orch"
    check parse(c).rejects("listed twice")
    c = baseConfig()
    c.modules[0].state_assignment = Opt.some("s1")
    c.modules[1].state_assignment = Opt.some("s1")
    check parse(c).rejects("share a state assignment")
    c = baseConfig()
    c.modules[1].state_assignment = Opt.some("..")
    check parse(c).rejects("state assignment")
    c = baseConfig()
    c.modules[1].requested_permissions = Opt.some(
      @[
        LcnAppPermission(permission: "p", constraints: @[0xa0'u8]),
        LcnAppPermission(permission: "p", constraints: @[0xa0'u8]),
      ]
    )
    check parse(c).rejects("repeats")
    c = baseConfig()
    c.modules[1].implements = Opt.some(@[root(1), root(1)])
    check parse(c).rejects("repeats")

  test "ordering names listed instances, without a self edge, a cycle or the orchestration instance as a dependent":
    proc ordered(pairs: openArray[(string, string)]): LcnAppConfig =
      result = baseConfig()
      result.modules.add(staticModule("meter-2", "meter_module", "meter"))
      var o: seq[LcnAppOrdering]
      for (p, d) in pairs:
        o.add(LcnAppOrdering(prerequisite: p, dependent: d))
      result.ordering = Opt.some(o)

    check parse(ordered([("meter-1", "ghost")])).rejects("not in modules")
    check parse(ordered([("meter-1", "meter-1")])).rejects("one instance twice")
    check parse(ordered([("meter-1", "meter-2"), ("meter-2", "meter-1")])).rejects(
      "cycle"
    )
    check parse(ordered([("meter-1", "orch")])).rejects("orchestration instance")
    check parse(ordered([("meter-1", "meter-2"), ("orch", "meter-2")])).isOk

  test "deadlines are 1 ms to 1 h and paths are absolute [IMPL]":
    var c = baseConfig()
    c.runtime.startup_deadline_ms = Opt.some(0'u32)
    check parse(c).rejects("startup_deadline_ms")
    c = baseConfig()
    c.runtime.stop_deadline_ms = Opt.some(3_600_001'u32)
    check parse(c).rejects("stop_deadline_ms")
    c = baseConfig()
    c.runtime.shutdown_grace_ms = Opt.some(250'u32)
    check parse(c).get.shutdownGrace.inMilliseconds == 250
    c = baseConfig()
    c.runtime.work_dir = "relative/w"
    check parse(c).rejects("work_dir must be an absolute path")
    c = baseConfig()
    # Logos text never holds NUL, so the schema already refuses it.
    c.runtime.state_root = Opt.some(work / "s\0x")
    check parse(c).isErr
    c = baseConfig()
    c.modules[1].implementation = LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_dynamic,
      arm_Direct_dynamic: LcnAppImplementationARDirectDynamicMap(
        artifact:
          LcnAppArtifact(id: "a", local_path: "libsensor.so", hash: newSeq[byte](32))
      ),
    )
    check parse(c).rejects("local_path must be an absolute path")

  test "[RUN-0741] [IMPL] store_dir is absolute and apart from work_dir and state_root; an identity needs it":
    var c = baseConfig()
    c.runtime.store_dir = Opt.some(work / "store")
    c.runtime.runtime_instance_id = Opt.some("rt-1")
    let ok = parse(c).get
    check ok.storeDir == Opt.some(work / "store")
    check ok.runtimeInstanceId == "rt-1"
    c.runtime.store_dir = Opt.some("relative/store")
    check parse(c).rejects("store_dir must be an absolute path")
    c.runtime.store_dir = Opt.some(work / "w")
    check parse(c).rejects("store_dir and work_dir must be apart")
    c.runtime.store_dir = Opt.some(work / "w" / "store")
    check parse(c).rejects("store_dir and work_dir must be apart")
    c.runtime.store_dir = Opt.some(work)
    check parse(c).rejects("store_dir and work_dir must be apart")
    c.runtime.store_dir = Opt.some(work / "s" / "store")
    c.runtime.state_root = Opt.some(work / "s")
    check parse(c).rejects("store_dir and state_root must be apart")
    c = baseConfig()
    c.runtime.runtime_instance_id = Opt.some("rt-1")
    check parse(c).rejects("runtime_instance_id needs store_dir")

  test "[RUN-0741] [IMPL-DECISION G55] declarations: one per module name, each a valid record":
    proc declaration(module, binding: string): LcnAppDeclaration =
      LcnAppDeclaration(
        module: module,
        implementation: LcnAppImplementation(
          kind: LcnAppImplementationKind.Direct_static,
          arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
        ),
      )

    var c = baseConfig()
    c.runtime.state_root = Opt.some(work / "state")
    var keep = declaration("meter_module", "meter")
    keep.persistent_state = Opt.some(true)
    c.declarations = Opt.some(@[keep, declaration("other_module", "other")])
    let ok = parse(c).get
    check ok.declarations.len == 2
    check ok.declarations[0].record.module == "meter_module"
    check ok.declarations[0].record.binding == "meter"
    check ok.declarations[0].persistentState
    check not ok.declarations[1].persistentState
    c.declarations = Opt.some(newSeq[LcnAppDeclaration]())
    check parse(c).rejects("declarations is present but empty")
    c.declarations = Opt.some(
      @[declaration("meter_module", "meter"), declaration("meter_module", "x")]
    )
    check parse(c).rejects("module meter_module is declared twice")
    var empty = declaration("meter_module", "meter")
    empty.implements = Opt.some(newSeq[SchemaCommitment]())
    c.declarations = Opt.some(@[empty])
    check parse(c).rejects("declaration meter_module: implements is present but empty")
    c.declarations = Opt.some(@[keep])
    c.runtime.state_root = Opt.none(string)
    check parse(c).rejects("persistent_state needs state_root")

  test "[IMPL] the names the Runtime assigns are refused in the configuration":
    let form = "m-" & repeat("0a", 16) & "-1"
    check isRuntimeForm(form)
    check not isRuntimeForm("m-" & repeat("0A", 16) & "-1")
    check not isRuntimeForm("m-" & repeat("0a", 16) & "-")
    check not isRuntimeForm("meter-1")
    var c = baseConfig()
    c.modules[1].instance = form
    check parse(c).rejects("Runtime-assigned name form")
    c = baseConfig()
    c.modules[1].state_assignment = Opt.some("s-" & repeat("0a", 16) & "-7")
    check parse(c).rejects("Runtime-assigned name form")
    c = baseConfig()
    c.modules[1].instance = "p-" & repeat("0a", 16) & "-2"
    check parse(c).rejects("Runtime-assigned name form")

  test "[RUN-0740] docs/HOST-CONFIG.md names the identifier and carries the schema verbatim":
    let root = currentSourcePath().parentDir.parentDir
    let doc = readFile(root / "docs" / "HOST-CONFIG.md")
    check ("# Host configuration: `" & AppConfigFormat & "`") in doc
    check (
      "```cddl\n" & readFile(root / "src/logos_core/runtime/host_config.cddl") & "```"
    ) in doc

# The test orchestrator --------------------------------------------------------------
#
# A consumer-only module for the orchestration role. Module code runs on the
# engine's workers, so its state is in atomics.

type OrchMode = enum
  omPlain ## LOGOS_OK at once
  omShutdown ## `shutdown_runtime` from its own initialization
  omStartBroken ## `start_module` on `broken-1` from its own initialization
  omWaitProbe ## `logos_runtime_wait_for_shutdown` from its own initialization
  omAutostart ## after initialization, its own thread starts the deployment

const Targets = [
  ("test_orchestrator", "orch"),
  ("meter_module", "meter-1"),
  ("sensor_module", "sensor-1"),
]

const AlreadyRequested = 1000 ## an orchestrator result: intent was not uninitialized

var
  orchMode: Atomic[int]
  orchFail: Atomic[bool] ## MODULE_ERROR at the end of initialization
  orchGate, orchDestroyGate: Atomic[bool] ## true while closed
  orchNames, orchInits, orchDestroys: Atomic[int]
  orchRc: Atomic[pointer] ## the latest initialization's Runtime Control binding
  orchHandle: Atomic[pointer] ## the host handle, for omWaitProbe
  orchInitCode: Atomic[int] ## what its own call from initialization returned
  orchResults: array[Targets.len + 1, Atomic[int]]
    ## per target, the start's code or AlreadyRequested; then a stale start
  orchThreadLive, orchThreadDone: Atomic[bool]
  orchCalls: Atomic[int]
    ## calls through its binding not yet past `release_response`: a module
    ## releases every response before its `_MODULE_destroy` returns (INTERFACE
    ## l.1619, l.3831), so the destroy waits for these, the test's own included
  orchThread: Thread[ptr LogosRuntimeControlBinding]

proc copyBytes(p: ptr UncheckedArray[uint8], n: csize_t): seq[byte] =
  result = newSeq[byte](int(n))
  for i in 0 ..< int(n):
    result[i] = p[i]

proc ec(r: LogosResult): ErrorCode =
  errorCode(int64(r.code)).get

proc text(r: LogosResult): string =
  if r.message.isNil:
    ""
  else:
    $r.message

proc rcCall(
    rc: ptr LogosRuntimeControlBinding, name: string, params: openArray[byte]
): (ErrorCode, seq[byte]) {.gcsafe.} =
  discard orchCalls.fetchAdd(1)
  defer:
    discard orchCalls.fetchSub(1)
  var buf: ptr UncheckedArray[uint8]
  var len: csize_t
  let r = rc.vtable.call(
    rc,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr buf,
    addr len,
  )
  result[0] = r.ec
  if buf != nil:
    result[1] = copyBytes(buf, len)
    rc.vtable.releaseResponse(rc, buf, len)

proc startModule(
    rc: ptr LogosRuntimeControlBinding, module, instance: string, expected: Opt[uint64]
): ErrorCode {.gcsafe.} =
  rcCall(
    rc,
    "start_module",
    encode(
      LogosNSRuntimeControlStartModuleRequest(
        module: module,
        instance: Opt.some(instance),
        expected_execution_revision: expected,
      )
    ).tryGet,
  )[0]

proc readiness(
    rc: ptr LogosRuntimeControlBinding, module, instance: string
): Result[LogosNSRuntimeControlGetReadinessResponse, ErrorCode] {.gcsafe.} =
  let (c, response) = rcCall(
    rc,
    "get_readiness",
    encode(
      LogosNSRuntimeControlGetReadinessRequest(
        module: module, instance: Opt.some(instance)
      )
    ).tryGet,
  )
  if c != ecOk:
    return err(c)
  ok(LogosNSRuntimeControlGetReadinessResponse.decode(response).tryGet)

proc orchestrate(rc: ptr LogosRuntimeControlBinding) {.thread.} =
  ## [SPEC RUNTIME l.3709-3712; RUN-0025] The orchestrator's own logic: a
  ## conditional start of every target that was never started.
  var meterRevision = 0'u64
  for i, (module, instance) in Targets:
    let g = rc.readiness(module, instance)
    if g.isErr:
      orchResults[i].store(ord(g.error))
      continue
    let x = g.get.execution.get
    if instance == "meter-1":
      meterRevision = x.revision
    if x.intent.kind != LogosNSRuntimeControlExecutionStateIntentChoiceKind.Uninitialized:
      orchResults[i].store(AlreadyRequested)
      continue
    orchResults[i].store(ord(rc.startModule(module, instance, Opt.some(x.revision))))
  # The revision read before the start is stale now.
  orchResults[Targets.len].store(
    ord(rc.startModule("meter_module", "meter-1", Opt.some(meterRevision)))
  )
  orchThreadDone.store(true)

proc orchName(): cstring {.cdecl.} =
  orchNames.atomicInc
  "test_orchestrator"

proc orchInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  orchInits.atomicInc
  orchRc.store(input.runtimeControl)
  while orchGate.load:
    sleep(1)
  {.cast(gcsafe).}:
    case OrchMode(orchMode.load)
    of omPlain:
      discard
    of omShutdown:
      orchInitCode.store(
        ord(rcCall(input.runtimeControl, "shutdown_runtime", [0xA0'u8])[0])
      )
    of omStartBroken:
      orchInitCode.store(
        ord(
          input.runtimeControl.startModule("meter_module", "broken-1", Opt.none(uint64))
        )
      )
    of omWaitProbe:
      orchInitCode.store(
        ord(runtimeWaitForShutdown(cast[ptr LogosRuntimeHandle](orchHandle.load)).ec)
      )
    of omAutostart:
      orchThreadLive.store(true)
      createThread(orchThread, orchestrate, input.runtimeControl)
  if orchFail.load:
    result.code = CErrorCode(ord(ecModule))
    result.message = "cannot orchestrate"
    return
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc orchDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  while orchDestroyGate.load:
    sleep(1)
  if orchThreadLive.load:
    joinThread(orchThread) # its calls end before the binding does
    orchThreadLive.store(false)
  while orchCalls.load > 0:
    sleep(1)
  deallocShared(module)
  orchDestroys.atomicInc

proc orchTable(): seq[(string, pointer)] =
  @[
    ("logos_test_orchestrator_MODULE_name", cast[pointer](orchName)),
    ("logos_test_orchestrator_MODULE_init", cast[pointer](orchInit)),
    ("logos_test_orchestrator_MODULE_destroy", cast[pointer](orchDestroy)),
  ]

proc resetOrchestrator() =
  orchMode.store(ord(omPlain))
  orchFail.store(false)
  orchGate.store(false)
  orchDestroyGate.store(false)
  orchNames.store(0)
  orchInits.store(0)
  orchDestroys.store(0)
  orchRc.store(nil)
  orchHandle.store(nil)
  orchInitCode.store(-1)
  for r in orchResults.mitems:
    r.store(-1)
  orchThreadDone.store(false)

# Host calls ---------------------------------------------------------------------------

let sensorLib = buildKitLibrary("sensor_impl.nim", "hostsensor")

proc digestOfFile(path: string): seq[byte] =
  var h: Blake3Hasher
  h.init()
  let bytes = readFile(path)
  h.update(bytes.toOpenArrayByte(0, bytes.high))
  @(h.finish())

var handles = 0

proc deployment(extra: seq[LcnAppModule] = @[]): LcnAppConfig =
  ## The orchestrator and the meter, each in its own work directory.
  inc handles
  result = baseConfig()
  result.runtime.work_dir = work / ("h" & $handles)
  result.runtime.state_root = Opt.some(work / ("h" & $handles) / "state")
  result.modules.add(extra)

proc broken(): LcnAppModule =
  ## A meter whose expected primary contract it does not have.
  result = staticModule("broken-1", "meter_module", "meter")
  result.primary_contract = Opt.some(root(0))

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

proc runtimeConfig(
    bytes: openArray[byte], format: cstring = AppConfigFormat
): LogosRuntimeConfig =
  LogosRuntimeConfig(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeConfig)),
    configurationFormat: format,
    configuration:
      if bytes.len > 0:
        cast[ptr UncheckedArray[uint8]](unsafeAddr bytes[0])
      else:
        nil,
    configurationLen: csize_t(bytes.len),
  )

proc create(c: LcnAppConfig): ptr LogosRuntimeHandle =
  let bytes = c.encode.get
  var cfg = runtimeConfig(bytes)
  check runtimeCreate(addr cfg, addr result).ec == ecOk

proc nativeBinding(
    id: cstring, symbols: var seq[LogosRuntimeNativeSymbol]
): LogosRuntimeNativeBinding =
  LogosRuntimeNativeBinding(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeNativeBinding)),
    binding: id,
    symbols:
      if symbols.len > 0:
        cast[ptr UncheckedArray[LogosRuntimeNativeSymbol]](addr symbols[0])
      else:
        nil,
    symbolCount: csize_t(symbols.len),
  )

proc register(
    rt: ptr LogosRuntimeHandle, id: string, table: openArray[(string, pointer)]
): LogosResult =
  var names: seq[string]
  for (n, _) in table:
    names.add(n)
  var symbols = newSeq[LogosRuntimeNativeSymbol](table.len)
  for i in 0 ..< table.len:
    symbols[i] = LogosRuntimeNativeSymbol(
      name: cstring(names[i]), address: cast[LogosRuntimeSymbolAddress](table[i][1])
    )
  var b = nativeBinding(cstring(id), symbols)
  runtimeRegisterBinding(rt, addr b)

proc registered(c: LcnAppConfig): ptr LogosRuntimeHandle =
  ## A handle for `c` with the orchestrator and meter bindings registered.
  result = create(c)
  check result.register("orchestrator", orchTable()).ec == ecOk
  check result.register("meter", meterModuleStaticSymbols()).ec == ecOk

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 20): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc finish(rt: ptr LogosRuntimeHandle) =
  ## Request, wait and destroy, each OK.
  orchGate.store(false)
  orchDestroyGate.store(false)
  check runtimeRequestShutdown(rt).ec == ecOk
  check runtimeWaitForShutdown(rt).ec == ecOk
  check runtimeDestroy(rt).ec == ecOk

proc state(rt: ptr LogosRuntimeHandle, instance: string): ModuleState =
  engineOf(rt).view(instance).tryGet.state

proc failureOf(rt: ptr LogosRuntimeHandle, instance: string): string =
  let v = engineOf(rt).view(instance).tryGet
  if v.failure.isSome: v.failure.get.classification else: ""

var
  startCode, waitCode: Atomic[int] ## the call's code, -1 while it runs
  otherThreadCode: Atomic[int]

proc startOn(rt: ptr LogosRuntimeHandle) {.thread.} =
  startCode.store(ord(runtimeStart(rt).ec))

proc waitOn(rt: ptr LogosRuntimeHandle) {.thread.} =
  waitCode.store(ord(runtimeWaitForShutdown(rt).ec))

proc failOn(rt: ptr LogosRuntimeHandle) {.thread.} =
  otherThreadCode.store(ord(runtimeStart(nil).ec))

# Structures and results ---------------------------------------------------------------

suite "run.host-api: structures and results (RUNTIME §13.1, §13.2, §13.4)":
  setup:
    resetOrchestrator()

  test "[RUN-0719] [RUN-0720] [RUN-0721] the version and size come first; past version 1's fields nothing is read":
    let bytes = deployment().encode.get
    var rt = cast[ptr LogosRuntimeHandle](1)
    var cfg = runtimeConfig(bytes, nil) # a null format is not reached
    cfg.abiVersion = 2
    check runtimeCreate(addr cfg, addr rt).ec == ecVersionMismatch
    check rt == nil
    cfg = runtimeConfig(bytes, nil)
    cfg.structSize = csize_t(RuntimeConfigV1Extent - 1)
    check runtimeCreate(addr cfg, addr rt).ec == ecVersionMismatch
    cfg.structSize = 0
    check runtimeCreate(addr cfg, addr rt).ec == ecVersionMismatch
    # A later version's larger structure, its tail filled with garbage.
    var larger = newSeq[byte](sizeof(LogosRuntimeConfig) + 64)
    for b in larger.mitems:
      b = 0xFF
    cfg = runtimeConfig(bytes)
    cfg.structSize = csize_t(larger.len)
    copyMem(addr larger[0], addr cfg, sizeof(cfg))
    check runtimeCreate(cast[ptr LogosRuntimeConfig](addr larger[0]), addr rt).ec == ecOk
    check rt != nil
    check runtimeDestroy(rt).ec == ecOk
    # The binding structure has the same two checks.
    rt = create(deployment())
    var symbols = @[
      LogosRuntimeNativeSymbol(
        name: "logos_test_orchestrator_MODULE_name",
        address: cast[LogosRuntimeSymbolAddress](orchName),
      )
    ]
    var b = nativeBinding(nil, symbols) # a null identifier is not reached
    b.abiVersion = 0
    check runtimeRegisterBinding(rt, addr b).ec == ecVersionMismatch
    b = nativeBinding(nil, symbols)
    b.structSize = csize_t(NativeBindingV1Extent - 1)
    check runtimeRegisterBinding(rt, addr b).ec == ecVersionMismatch
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0753] [RUN-0755] null arguments are INVALID_PARAMS, and the output handle is cleared first":
    var rt = cast[ptr LogosRuntimeHandle](1)
    check runtimeCreate(nil, addr rt).ec == ecInvalidParams
    check rt == nil
    let bytes = deployment().encode.get
    var cfg = runtimeConfig(bytes)
    check runtimeCreate(addr cfg, nil).ec == ecInvalidParams
    check runtimeRegisterBinding(nil, nil).ec == ecInvalidParams
    check runtimeStart(nil).ec == ecInvalidParams
    check runtimeRequestShutdown(nil).ec == ecInvalidParams
    check runtimeWaitForShutdown(nil).ec == ecInvalidParams
    check runtimeDestroy(nil).ec == ecInvalidParams
    rt = create(deployment())
    check runtimeRegisterBinding(rt, nil).ec == ecInvalidParams
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0741] [RUN-0742] the format and the bytes: every failure is INVALID_PARAMS and creates nothing":
    let bytes = deployment().encode.get
    var rt = cast[ptr LogosRuntimeHandle](1)
    for f in [cstring(nil), cstring(""), cstring("logos-core-nim.app-config.v2")]:
      var cfg = runtimeConfig(bytes, f)
      check runtimeCreate(addr cfg, addr rt).ec == ecInvalidParams
      check rt == nil
    var cfg = runtimeConfig(bytes)
    cfg.configuration = nil
    check runtimeCreate(addr cfg, addr rt).ec == ecInvalidParams
    check rt == nil
    # No bytes at all, malformed and non-deterministic CBOR carry their detail.
    cfg.configurationLen = 0
    var r = runtimeCreate(addr cfg, addr rt)
    check r.ec == ecInvalidParams
    check copyBytes(r.detail, r.detailLen) == invalidParamsDetail(iprMalformedCbor)
    let nd = @[0x18'u8, 0x05]
    cfg = runtimeConfig(nd)
    r = runtimeCreate(addr cfg, addr rt)
    check r.ec == ecInvalidParams
    check copyBytes(r.detail, r.detailLen) ==
      invalidParamsDetail(iprNonDeterministicCbor)
    # A semantic failure has a message and no detail.
    var c = deployment()
    c.orchestration = "nobody"
    let sem = c.encode.get
    cfg = runtimeConfig(sem)
    r = runtimeCreate(addr cfg, addr rt)
    check r.ec == ecInvalidParams and "orchestration names no instance" in r.text
    check r.detail == nil and r.detailLen == 0
    check rt == nil
    # [IMPL] create opened nothing: no work directory yet.
    c = deployment()
    rt = create(c)
    check not dirExists(c.runtime.work_dir)
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0764] a result's message lives in its thread until that thread's next call; OK has none; 512 bytes at most":
    var rt: ptr LogosRuntimeHandle
    let bad = runtimeCreate(nil, addr rt)
    let p = bad.message
    check $p == "config is null"
    otherThreadCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, failOn, nil)
    joinThread(t)
    check otherThreadCode.load == ord(ecInvalidParams)
    check bad.message == p and $p == "config is null" # another thread's call
    rt = create(deployment())
    let good = runtimeRequestShutdown(rt)
    check good.ec == ecOk and good.message.isNil and good.detail.isNil
    check good.detailLen == 0
    # A message is cut to 512 bytes before a continuation byte.
    let long = "logos_" & repeat("é", 600) & "_MODULE_init"
    let r = rt.register("x", [(long, nil.pointer)])
    check r.ec == ecNotReady # shutdown was requested: call order first
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk
    rt = create(deployment())
    let cut = rt.register("x", [(long, nil.pointer)])
    check cut.ec == ecInvalidParams
    check cut.text.startsWith("symbol logos_é")
    check cut.text.len <= 512 and cut.text.len > 500
    check validateUtf8(cut.text) == -1
    check runtimeDestroy(rt).ec == ecOk

# Registration -------------------------------------------------------------------------

suite "run.host-api: registration (RUNTIME §13.3)":
  setup:
    resetOrchestrator()

  test "[RUN-0748] [RUN-1084] a table's own properties are checked; nothing invalid is kept":
    let rt = create(deployment())
    var t = orchTable()
    check rt.register("orch-bad", @[t[0], t[0]] & t[1 .. 2]).text.contains(
      "appears twice"
    )
    check rt.register("orch-bad", []).text.contains("the symbol table is empty")
    check rt.register("orch-bad", @[(t[0][0], nil.pointer)] & t[1 .. 2]).text.contains(
      "null address"
    )
    check rt.register("orch-bad", t & @[("not_a_symbol", t[0][1])]).ec == ecInvalidParams
    check rt.register("orch-bad", t & meterModuleStaticSymbols()).text.contains(
      "two modules"
    )
    check rt.register("orch-bad", @[t[0], t[2]]).text.contains("lacks")
    check rt.register("", t).ec == ecInvalidParams
    check rt.register(repeat('b', 129), t).ec == ecInvalidParams
    # Null pointers inside the structure.
    var symbols = @[
      LogosRuntimeNativeSymbol(
        name: nil, address: cast[LogosRuntimeSymbolAddress](orchName)
      )
    ]
    var b = nativeBinding("orch-bad", symbols)
    check runtimeRegisterBinding(rt, addr b).text == "a symbol name is null"
    b = nativeBinding(nil, symbols)
    check runtimeRegisterBinding(rt, addr b).ec == ecInvalidParams
    b = nativeBinding("orch-bad", symbols)
    b.symbols = nil
    check runtimeRegisterBinding(rt, addr b).ec == ecInvalidParams
    # [RUN-0756] None of these was kept: the identifier is still free.
    check rt.register("orch-bad", t).ec == ecOk
    check rt.register("orch-bad", t).text.contains("already registered")
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-1085] [RUN-0747] registering runs no module code and creates no instance":
    var c = deployment()
    let rt = registered(c)
    check rt.register("spare", orchTable()).ec == ecOk # never named by a record
    check orchNames.load == 0 and orchInits.load == 0
    check engineOf(rt) == nil
    check runtimeStart(rt).ec == ecOk
    let ids = engineOf(rt).list().mapIt(it.instance)
    check ids == @["orch", "meter-1"]
    rt.finish()

  test "[RUN-0749] the table is copied: the caller's storage may change once the call returns":
    let rt = create(deployment())
    var names = orchTable().mapIt(it[0])
    var symbols = newSeq[LogosRuntimeNativeSymbol]()
    for i, (_, p) in orchTable():
      symbols.add(
        LogosRuntimeNativeSymbol(
          name: cstring(names[i]), address: cast[LogosRuntimeSymbolAddress](p)
        )
      )
    var id = "orchestrator"
    var b = nativeBinding(cstring(id), symbols)
    check runtimeRegisterBinding(rt, addr b).ec == ecOk
    for n in names.mitems:
      for ch in n.mitems:
        ch = 'z'
    for s in symbols.mitems:
      s.address = nil
    id[0] = 'x'
    check rt.register("meter", meterModuleStaticSymbols()).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    check rt.state("orch") == msReady
    rt.finish()

  test "[RUN-0758] registration after start, or after a shutdown request, is NOT_READY":
    var rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    check rt.register("late", orchTable()).ec == ecNotReady
    rt.finish()
    rt = create(deployment())
    check runtimeRequestShutdown(rt).ec == ecOk
    check rt.register("late", orchTable()).ec == ecNotReady
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-1086] a table without a call symbol the surface needs registers, and its instance fails binding":
    let rt = create(deployment())
    var t = meterModuleStaticSymbols()
    var dropped = false
    var kept: seq[(string, pointer)]
    for e in t:
      if not dropped and "_CALL_" in e[0]:
        dropped = true
      else:
        kept.add(e)
    check dropped
    check rt.register("orchestrator", orchTable()).ec == ecOk
    check rt.register("meter", kept).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    check engineOf(rt).start("meter-1").tryGet.state == msError
    check rt.failureOf("meter-1") == "loader-abi-invalid"
    rt.finish()

# Startup ------------------------------------------------------------------------------

suite "run.host-api: startup (RUNTIME §13.2, l.1640) [G190] [G191]":
  setup:
    resetOrchestrator()

  test "[RUN-0309] [RUN-0023] [RUN-0784] [RUN-0724] [RUN-0746] [IMPL-DECISION G191] start realizes the orchestration instance only, with intent requested":
    let rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    let all = engineOf(rt).list()
    check all.len == 2
    check all[0].instance == "orch" and all[0].state == msReady and all[0].orchestration
    check all[0].intentOrigin.host
    check all[1].instance == "meter-1" and all[1].state == msUnloaded
    check all[1].execution.intent == inUninitialized and not all[1].orchestration
    # What the orchestrator itself observes (G191 interim).
    let rc = cast[ptr LogosRuntimeControlBinding](orchRc.load)
    let g = rc.readiness("test_orchestrator", "orch").get
    check g.execution.get.intent.kind ==
      LogosNSRuntimeControlExecutionStateIntentChoiceKind.Requested
    check g.execution.get.intent_revision == all[0].execution.intentRevision
    check g.execution.get.intent_revision.isSome
    rt.finish()

  test "[RUN-0725] [RUN-0025] with no further host call, the orchestrator starts the deployment by conditional start":
    orchMode.store(ord(omAutostart))
    let rt = registered(deployment(@[sensor()]))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check orchResults[0].load == AlreadyRequested # itself: not restarted
    check orchResults[1].load == ord(ecOk)
    check orchResults[2].load == ord(ecOk)
    check orchResults[3].load == ord(ecInvalidParams) # a stale revision
    check rt.state("meter-1") == msReady
    check rt.state("sensor-1") == msReady # direct_dynamic, verified by its digest
    rt.finish()

  test "[RUN-0757] start is attempted once, and never after a shutdown request":
    var rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    check runtimeStart(rt).ec == ecNotReady
    rt.finish()
    rt = registered(deployment())
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeStart(rt).ec == ecNotReady
    check engineOf(rt) == nil
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0759] [IMPL-DECISION G190] a shutdown accepted before ready is CANCELLED, and stays CANCELLED when the init then fails":
    for fail in [false, true]:
      resetOrchestrator()
      orchMode.store(ord(omShutdown))
      orchFail.store(fail)
      let rt = registered(deployment())
      check runtimeStart(rt).ec == ecCancelled
      check waitUntil(
        proc(): bool =
          orchInitCode.load != -1
      )
      check orchInitCode.load == ord(ecOk) # the request was accepted
      check runtimeWaitForShutdown(rt).ec == ecOk
      check runtimeDestroy(rt).ec == ecOk

  test "[IMPL] R1: a shutdown request overlapping start is accepted, and start is CANCELLED":
    orchGate.store(true)
    let rt = registered(deployment())
    startCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, startOn, rt)
    check waitUntil(
      proc(): bool =
        orchInits.load == 1
    )
    check runtimeRequestShutdown(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        startCode.load != -1
    )
    check startCode.load == ord(ecCancelled)
    orchGate.store(false)
    joinThread(t)
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[IMPL-DECISION G190] [RUN-0737] [RUN-0765] a failed start: MODULE_ERROR or NOT_AUTHORISED, nothing stopped, and the handle shuts down":
    orchFail.store(true)
    var rt = registered(deployment())
    var r = runtimeStart(rt)
    check r.ec == ecModule and "initialization-failed" in r.text
    check rt.state("orch") == msError
    check engineOf(rt).start("meter-1").tryGet.state == msReady # still running
    rt.finish()
    resetOrchestrator()
    orchGate.store(true)
    var c = deployment()
    c.runtime.startup_deadline_ms = Opt.some(50'u32)
    rt = registered(c)
    r = runtimeStart(rt)
    check r.ec == ecModule and "startup-timeout" in r.text
    rt.finish()
    resetOrchestrator()
    rt = registered(deployment())
    rt.setPolicyForTests(
      proc(): AuthzPolicy =
        denying(AuthzRule(action: Opt.some(aaExecute), target: "orch", outcome: azDeny))
    )
    check runtimeStart(rt).ec == ecNotAuthorised
    check orchInits.load == 0
    rt.finish()

  test "[RUN-0682] a dependent that fails to start leaves start OK":
    orchMode.store(ord(omStartBroken))
    let rt = registered(deployment(@[broken()]))
    check runtimeStart(rt).ec == ecOk
    check orchInitCode.load != -1
    check rt.state("broken-1") == msError
    check rt.state("orch") == msReady
    rt.finish()

  test "[IMPL-DECISION S4] [IMPL] R2: a static binding never registered fails start before anything runs":
    let rt = create(deployment())
    check rt.register("orchestrator", orchTable()).ec == ecOk
    let r = runtimeStart(rt)
    check r.ec == ecInvalidParams
    check "meter-1" in r.text and "meter" in r.text
    check engineOf(rt) == nil and orchNames.load == 0
    # The attempt is spent: registration is closed and destroy needs a shutdown.
    check rt.register("meter", meterModuleStaticSymbols()).ec == ecNotReady
    check runtimeDestroy(rt).ec == ecNotReady
    check runtimeStart(rt).ec == ecNotReady
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[IMPL-DECISION S4] [IMPL-DECISION G55] a declaration naming a static binding never registered fails start too":
    var c = deployment()
    c.declarations = Opt.some(
      @[
        LcnAppDeclaration(
          module: "spare_module",
          implementation: LcnAppImplementation(
            kind: LcnAppImplementationKind.Direct_static,
            arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: "spare"),
          ),
        )
      ]
    )
    let rt = registered(c)
    let r = runtimeStart(rt)
    check r.ec == ecInvalidParams
    check "spare_module" in r.text and "spare" in r.text
    check engineOf(rt) == nil and orchNames.load == 0
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[IMPL] the work directory and state root are made private when missing":
    let c = deployment()
    let rt = registered(c)
    check runtimeStart(rt).ec == ecOk
    check dirExists(c.runtime.work_dir) and dirExists(c.runtime.state_root.get)
    when defined(posix):
      check getFilePermissions(c.runtime.work_dir) ==
        {fpUserRead, fpUserWrite, fpUserExec}
    rt.finish()

# Persistent Runtime state ---------------------------------------------------------------

proc persistent(c: LcnAppConfig, base: string, id = Opt.none(string)): LcnAppConfig =
  ## `c` with the store and state root under `base`, shared by every run.
  result = c
  result.runtime.store_dir = Opt.some(base / "store")
  result.runtime.state_root = Opt.some(base / "state")
  result.runtime.runtime_instance_id = id

proc orchBinding(): ptr LogosRuntimeControlBinding =
  cast[ptr LogosRuntimeControlBinding](orchRc.load)

proc recoverRequest(instance: string, v: InstanceView): seq[byte] =
  encode(
    LogosNSRuntimeControlRecoverModuleRequest(
      module: v.module,
      instance: instance,
      expected_execution_revision: v.execution.revision,
    )
  ).tryGet

proc selfId(): string =
  let rc = cast[ptr LogosRuntimeControlBinding](orchRc.load)
  let (code, response) = rcCall(rc, "get_self", [0xA0'u8])
  check code == ecOk
  LogosNSRuntimeControlGetSelfResponse.decode(response).tryGet.consumer.runtime_instance_id

suite "run.host-api: persistent Runtime state (I82) [G191] [G192]":
  setup:
    resetOrchestrator()

  test "[RUN-0698] [RUN-0646] [RUN-0632] [IMPL-DECISION G191] a restart resumes orchestration; retained intent waits for it":
    let base = work / "restart-1"
    orchMode.store(ord(omAutostart))
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check rt.state("meter-1") == msReady
    let orch1 = engineOf(rt).view("orch").tryGet
    let meter1 = engineOf(rt).view("meter-1").tryGet
    check meter1.intentOrigin.instance == "orch"
    rt.finish()
    resetOrchestrator()
    rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let orch2 = engineOf(rt).view("orch").tryGet
    check orch2.state == msReady
    check orch2.intentOrigin.host
    check orch2.execution.intentRevision == orch1.execution.intentRevision
    check orch2.execution.revision > orch1.execution.revision
    let meter2 = engineOf(rt).view("meter-1").tryGet
    check meter2.state == msUnloaded
    check meter2.execution.intent == inRequested
    check meter2.intentOrigin.instance == "orch"
    check meter2.execution.intentRevision == meter1.execution.intentRevision
    # The orchestrator resumes it, keeping its origin and intent revision.
    check rcCall(orchBinding(), "recover_module", recoverRequest("meter-1", meter2))[0] ==
      ecOk
    let meter3 = engineOf(rt).view("meter-1").tryGet
    check meter3.state == msReady
    check meter3.intentOrigin.instance == "orch"
    check meter3.execution.intentRevision == meter1.execution.intentRevision
    rt.finish()

  test "[RUN-0698] [IMPL-DECISION G191] orchestration stopped before shutdown is started again, with a diagnostic":
    let base = work / "restart-2"
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let before = engineOf(rt).view("orch").tryGet
    check engineOf(rt).stop("orch").tryGet.state == msUnloaded
    rt.finish()
    rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let after = engineOf(rt).view("orch").tryGet
    check after.state == msReady and after.intentOrigin.host
    check after.execution.intentRevision.get > before.execution.intentRevision.get
    check engineOf(rt).diagnostics.anyIt("whose intent was stopped" in it)
    rt.finish()

  test "[IMPL-DECISION G192] the Runtime's identity is the store's, or the configured one":
    let base = work / "restart-3"
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    let id = selfId()
    check id.len == 36
    rt.finish()
    rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check selfId() == id
    rt.finish()
    # Another configured identity for this store: refused before anything runs.
    rt = registered(persistent(deployment(), base, Opt.some("rt-other")))
    let r = runtimeStart(rt)
    check r.ec == ecInvalidParams
    check orchInits.load == 2
    rt.finish()
    # A new store takes the configured one.
    rt = registered(persistent(deployment(), work / "restart-4", Opt.some("rt-named")))
    check runtimeStart(rt).ec == ecOk
    check selfId() == "rt-named"
    rt.finish()

  test "[IMPL-DECISION G160] a configured instance whose declaration changed is refused before anything runs":
    let base = work / "restart-5"
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    rt.finish()
    var c = persistent(deployment(), base)
    c.modules[1].primary_contract = Opt.some(root(7))
    rt = registered(c)
    let r = runtimeStart(rt)
    check r.ec == ecInvalidParams
    check "meter-1" in r.text
    check orchInits.load == 1
    rt.finish()

  test "[IMPL] a retained instance whose static binding is no longer registered: start is OK, its recovery fails in the loader":
    let base = work / "restart-unbound"
    orchMode.store(ord(omAutostart))
    var rt = registered(persistent(deployment(), base))
    check runtimeStart(rt).ec == ecOk
    check waitUntil(
      proc(): bool =
        orchThreadDone.load
    )
    check rt.state("meter-1") == msReady
    rt.finish()
    resetOrchestrator()
    # The next configuration drops meter-1, and its binding is not registered.
    var c = persistent(deployment(), base)
    c.modules = c.modules.filterIt(it.instance != "meter-1")
    rt = create(c)
    check rt.register("orchestrator", orchTable()).ec == ecOk
    check runtimeStart(rt).ec == ecOk
    let v = engineOf(rt).view("meter-1").tryGet
    check v.state == msUnloaded and v.execution.intent == inRequested
    let (code, response) =
      rcCall(orchBinding(), "recover_module", recoverRequest("meter-1", v))
    check code == ecOk
    check LogosNSRuntimeControlRecoverModuleResponse.decode(response).tryGet.state.kind ==
      LogosNSRuntimeControlStateKind.Error
    check rt.failureOf("meter-1").startsWith("loader-")
    rt.finish()

  test "[IMPL] two handles on one store: the second start is MODULE_ERROR":
    let base = work / "restart-6"
    let a = registered(persistent(deployment(), base))
    check runtimeStart(a).ec == ecOk
    let b = registered(persistent(deployment(), base))
    let r = runtimeStart(b)
    check r.ec == ecModule and "in use" in r.text
    b.finish()
    a.finish()

# Shutdown and destruction -------------------------------------------------------------

suite "run.host-api: shutdown and destruction (RUNTIME §13.2, §10.2) [G60]":
  setup:
    resetOrchestrator()

  test "[RUN-0726] [RUN-0727] [RUN-0728] [RUN-0729] [RUN-0760] [RUN-0705] [RUN-0706] a request accepts at once; a wait initiates nothing; every wait gets the one result":
    let rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    waitCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, waitOn, rt)
    sleep(50)
    check waitCode.load == -1 # waiting alone starts nothing
    check rt.state("orch") == msReady
    orchDestroyGate.store(true)
    check runtimeRequestShutdown(rt).ec == ecOk # returns while the destroy is held
    check runtimeRequestShutdown(rt).ec == ecOk
    sleep(20)
    check waitCode.load == -1
    check runtimeDestroy(rt).ec == ecNotReady # [RUN-0761] not shut down yet
    orchDestroyGate.store(false)
    joinThread(t)
    check waitCode.load == ord(ecOk)
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check engineOf(rt).view("orch").tryGet.execution.intent == inRequested # kept
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0730] a shutdown through Runtime Control is the one a wait sees":
    let rt = registered(deployment())
    check runtimeStart(rt).ec == ecOk
    waitCode.store(-1)
    var t: Thread[ptr LogosRuntimeHandle]
    createThread(t, waitOn, rt)
    let rc = cast[ptr LogosRuntimeControlBinding](orchRc.load)
    check rcCall(rc, "shutdown_runtime", [0xA0'u8])[0] == ecOk
    joinThread(t)
    check waitCode.load == ord(ecOk)
    check runtimeRequestShutdown(rt).ec == ecOk # joins the completed one
    check runtimeDestroy(rt).ec == ecOk

  test "[IMPL-DECISION G60] [RUN-0733] [RUN-0734] cleanup past the grace is MODULE_ERROR; destroy waits for module code and can be retried":
    var c = deployment()
    c.runtime.shutdown_grace_ms = Opt.some(100'u32)
    let rt = registered(c)
    check runtimeStart(rt).ec == ecOk
    check runtimeDestroy(rt).text == "the Runtime has not shut down"
    orchDestroyGate.store(true)
    check runtimeRequestShutdown(rt).ec == ecOk
    let r = runtimeWaitForShutdown(rt)
    check r.ec == ecModule and "orch" in r.text
    check runtimeWaitForShutdown(rt).ec == ecModule
    let refused = runtimeDestroy(rt)
    check refused.ec == ecNotReady and "still running" in refused.text
    check runtimeWaitForShutdown(rt).ec == ecModule # the handle is still valid
    orchDestroyGate.store(false)
    var destroyed = false
    for _ in 0 ..< 10_000:
      if runtimeDestroy(rt).ec == ecOk:
        destroyed = true
        break
      sleep(1)
    check destroyed
    check orchDestroys.load == 1

  test "[RUN-0736] destroy before start, and after a shutdown that had no Runtime":
    var rt = create(deployment())
    check runtimeDestroy(rt).ec == ecOk
    rt = registered(deployment())
    check runtimeRequestShutdown(rt).ec == ecOk
    check runtimeWaitForShutdown(rt).ec == ecOk
    check runtimeDestroy(rt).ec == ecOk

  test "[RUN-0763] [IMPL] R3: a wait from module code is NOT_READY":
    orchMode.store(ord(omWaitProbe))
    let rt = registered(deployment())
    orchHandle.store(rt)
    check runtimeStart(rt).ec == ecOk
    check orchInitCode.load == ord(ecNotReady)
    rt.finish()

  test "100 rounds: a request against a wait on another thread, and destroy retried against completion":
    for _ in 0 ..< 100:
      resetOrchestrator()
      var rt = registered(deployment())
      check runtimeStart(rt).ec == ecOk
      waitCode.store(-1)
      var t: Thread[ptr LogosRuntimeHandle]
      createThread(t, waitOn, rt)
      check runtimeRequestShutdown(rt).ec == ecOk
      joinThread(t)
      check waitCode.load == ord(ecOk)
      check runtimeDestroy(rt).ec == ecOk
      rt = registered(deployment())
      check runtimeStart(rt).ec == ecOk
      check runtimeRequestShutdown(rt).ec == ecOk
      var tries = 0
      while runtimeDestroy(rt).ec != ecOk:
        inc tries
        check tries < 100_000
        if tries >= 100_000:
          break
