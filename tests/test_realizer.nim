## The Runtime's internal Module Loader for the direct strategies
## (`runtime/realizer.nim`): static registrations (RUNTIME §2.3, §13.3), symbol
## resolution and call-surface validation (§1.2, §2.2, §2.4), verified dynamic
## libraries (§3.6; LOADER §3, §12), and realize, release and get_status
## (LOADER §6, §7, §9, §10).
##
## Static modules are the kit modules of `tests/kit/` linked into this suite and
## registered through the tables their export templates generate, and small
## hand-written modules that break one rule each. Dynamic modules are the meter
## kit module and a marker library, built as shared libraries.

import std/[os, sequtils, strutils, tables]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/runtime/realizer
import ../src/logos_core/crypto/blake3
import ../src/logos_core/iface/[accept, names]
import ../src/logos_core/pins
import ../src/logos_core/runtime/config
import ./support/[kitbuild, kitruntime, tunerconfig]
import ./kit/[meter_impl, sensor_impl, shapes_impl]

let work = currentSourcePath().parentDir.parentDir / "build" / "realizer" / kitVariant
removeDir(work)
createDir(work)

proc services(publish = true): InitServices =
  InitServices(
    runtimeControl: addr rcBinding,
    publish: (if publish: publishOp else: nil),
    publishUserData: addr publishState,
    invocationAccess: LogosInvocationAccess(state: addr accessState, current: currentOp),
  )

proc staticRequest(
    instance, module, binding: string, state = Opt.none(string), publish = true
): RealizeRequest =
  RealizeRequest(
    moduleInstance: instance,
    descriptor:
      RealizationDescriptor(strategy: stDirectStatic, module: module, binding: binding),
    state: state,
    services: services(publish),
  )

proc fresh(): Realizer =
  newRealizer(work, Opt.some(work / "state"))

proc meterCall(x: Realization, channel: uint64): Call =
  call(
    x.binding.dispatch,
    x.binding.free,
    x.context,
    "read",
    diag("{\"channel\": " & $channel & "}"),
  )

# Hand-written static modules ------------------------------------------------------

type InitMode = enum
  imOk ## LOGOS_OK and a context
  imOkNull ## LOGOS_OK without a context
  imFail ## MODULE_ERROR with a message and no context
  imFailContext ## MODULE_ERROR that also returns a context
  imOkMessage ## LOGOS_OK, a context and a message

var
  initMode = imOk
  inits, destroys: int
  outWasNull: bool
  seenInput: LogosModuleInitInput
  seenStateDir: string
  contexts: seq[pointer]
  applyResult: LogosResult ## what `plainApply` answers
  applies: int
  seenApply: seq[byte]

proc plainName(): cstring {.cdecl.} =
  "plain_consumer"

proc otherName(): cstring {.cdecl.} =
  "other_module"

proc nullName(): cstring {.cdecl.} =
  nil

proc plainInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  inc inits
  outWasNull = outContext[] == nil
  seenInput = input[]
  seenStateDir = (if input.stateDir == nil: "" else: $input.stateDir)
  let ctx = cast[ptr LogosModuleContext](allocShared0(16))
  case initMode
  of imOk:
    outContext[] = ctx
  of imOkNull:
    deallocShared(ctx)
  of imFail:
    deallocShared(ctx)
    result.code = CErrorCode(ord(ecModule))
    result.message = "cannot start"
  of imFailContext:
    outContext[] = ctx
    result.code = CErrorCode(ord(ecModule))
  of imOkMessage:
    outContext[] = ctx
    result.message = "fine"
  if outContext[] == ctx:
    contexts.add(ctx)

proc plainDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  inc destroys
  doAssert cast[pointer](module) in contexts
  contexts.keepItIf(it != cast[pointer](module))
  deallocShared(module)

proc plainApply(
    module: ptr LogosModuleContext, cbor: ptr UncheckedArray[uint8], len: csize_t
): LogosResult {.cdecl.} =
  inc applies
  doAssert cast[pointer](module) in contexts
  seenApply = @(cbor.toOpenArray(0, int(len) - 1))
  applyResult

proc reset() =
  initMode = imOk
  inits = 0
  destroys = 0
  applyResult = LogosResult()
  applies = 0
  seenApply = @[]
  outWasNull = false
  seenInput = default(LogosModuleInitInput)
  seenStateDir = ""

proc plainTable(
    module = "plain_consumer", name: pointer = cast[pointer](plainName)
): seq[(string, pointer)] =
  let c = projectModule(module)
  @[
    ("logos_" & c & "_MODULE_name", name),
    ("logos_" & c & "_MODULE_init", cast[pointer](plainInit)),
    ("logos_" & c & "_MODULE_destroy", cast[pointer](plainDestroy)),
  ]

proc without(t: seq[(string, pointer)], name: string): seq[(string, pointer)] =
  doAssert t.anyIt(it[0] == name), name
  t.filterIt(it[0] != name)

proc replaced(
    t: seq[(string, pointer)], name: string, p: pointer
): seq[(string, pointer)] =
  doAssert t.anyIt(it[0] == name), name
  t.mapIt(
    if it[0] == name:
      (name, p)
    else:
      it
  )

# Call-surface and async-descriptor variants for the meter's table.

proc garbageSurface(outLen: ptr csize_t): ptr uint8 {.cdecl.} =
  var bytes {.global.} = [0xA0'u8, 0xFF]
  outLen[] = 2
  addr bytes[0]

proc nullSurface(outLen: ptr csize_t): ptr uint8 {.cdecl.} =
  outLen[] = 7
  nil

proc emptySurface(outLen: ptr csize_t): ptr uint8 {.cdecl.} =
  var bytes {.global.} = [0xA0'u8]
  outLen[] = 0
  addr bytes[0]

proc sensorSurface(outLen: ptr csize_t): ptr uint8 {.cdecl.} =
  ## The sensor module's descriptor, offered under the meter's name.
  let f = cast[ModuleCallSurfaceFn](sensorModuleStaticSymbols().filterIt(
    it[0] == "logos_sensor_module_MODULE_call_surface"
  )[0][1])
  f(outLen)

proc submitOp(
    module: ptr LogosModuleContext, invocation: ptr LogosProviderInvocation
) {.cdecl, gcsafe, raises: [].} =
  discard

var
  goodAsync = LogosAsyncProviderApi(
    abiVersion: AsyncProviderAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncProviderApi)),
    submit: submitOp,
  )
  badAsync = LogosAsyncProviderApi(
    abiVersion: 0, structSize: csize_t(sizeof(LogosAsyncProviderApi)), submit: submitOp
  )
  asyncCalls: int

proc goodAsyncApi(): ptr LogosAsyncProviderApi {.cdecl.} =
  inc asyncCalls
  addr goodAsync

proc badAsyncApi(): ptr LogosAsyncProviderApi {.cdecl.} =
  addr badAsync

proc nullAsyncApi(): ptr LogosAsyncProviderApi {.cdecl.} =
  nil

const
  meterName = "logos_meter_module_MODULE_name"
  meterSurface = "logos_meter_module_MODULE_call_surface"
  meterDispatchSym = "logos_meter_module_MODULE_dispatch"
  meterAsync = "logos_meter_module_MODULE_async_api"
  meterRead = "logos_meter_module_CALL_meter_Read"

proc realizeFails(
    r: Realizer,
    binding: string,
    entries: seq[(string, pointer)],
    module = "meter_module",
): LoaderError =
  r.registerStatic(binding, entries).tryGet
  let x = r.realize(staticRequest("i-" & binding, module, binding))
  doAssert x.isErr, binding & " was realized"
  x.error

# Static registration ----------------------------------------------------------------

suite "run.realizer: static registration (RUNTIME §2.3, §13.3) [IMPL]":
  test "[RUN-0079] [RUN-0745] the kit generates a complete registration table for each module":
    let t = meterModuleStaticSymbols()
    let names = t.mapIt(it[0])
    for s in ["name", "init", "destroy", "call_surface", "free", "dispatch"]:
      check ("logos_meter_module_MODULE_" & s) in names
    check meterRead in names
    check t.allIt(it[1] != nil)
    check checkStaticRegistration("meter", t).isOk
    check checkStaticRegistration("sensor", sensorModuleStaticSymbols()).isOk
    check checkStaticRegistration("shapes", shapesModuleStaticSymbols()).isOk

  test "[RUN-0748] empty tables, null addresses, duplicate names and duplicate binding identifiers are rejected":
    reset()
    check checkStaticRegistration("b", newSeq[(string, pointer)]()).isErr
    check checkStaticRegistration(
      "b", plainTable().replaced("logos_plain_consumer_MODULE_init", nil)
    ).isErr
    check checkStaticRegistration("b", plainTable() & plainTable()[0 .. 0]).isErr
    check checkStaticRegistration("", plainTable()).isErr
    check checkStaticRegistration('x'.repeat(129), plainTable()).isErr
    let r = fresh()
    check r.registerStatic("b", plainTable()).isOk
    check r.registerStatic("b", meterModuleStaticSymbols()).isErr
    # The existing registration is unchanged: it still realizes the consumer.
    check r.realize(staticRequest("i1", "plain_consumer", "b")).isOk
    check inits == 1

  test "[RUN-1084] malformed names, two module families and a missing unconditional symbol are rejected":
    let t = plainTable()
    for bad in [
      "plain_consumer_MODULE_init", "logos_plain_consumer_init",
      "logos_Plain_MODULE_init", "logos_plain_consumer_MODULE_start",
      "logos_plain_consumer_CALL_", "logos_plain_consumer_CALL_Meter_Read",
      "logos_plain__consumer_MODULE_free", "logos__MODULE_init",
    ]:
      checkpoint bad
      check checkStaticRegistration("b", t & @[(bad, cast[pointer](plainInit))]).isErr
    check checkStaticRegistration("b", t & meterModuleStaticSymbols()).isErr
    for s in ["name", "init", "destroy"]:
      checkpoint s
      check checkStaticRegistration("b", t.without("logos_plain_consumer_MODULE_" & s)).isErr
    # A canonical `_U` projection is one family.
    check checkStaticRegistration("b", plainTable("a__b_")).get.module == "a__b_"

  test "[RUN-0747] [RUN-1085] [RUN-0749] registration invokes no module code and keeps its own copy":
    reset()
    let r = fresh()
    var t = plainTable(name = cast[pointer](otherName))
    check r.registerStatic("b", t).isOk
    t.setLen(0) # the caller's table is gone
    check inits == 0 and destroys == 0
    # Only binding calls `_MODULE_name()`: here it does not match.
    check r.realize(staticRequest("i1", "plain_consumer", "b")).error.code ==
      lecAbiInvalid

# Binding --------------------------------------------------------------------------

suite "run.realizer: implementation binding (RUNTIME §1.2, §2.2-§2.4; LOADER §6) [IMPL]":
  test "[RUN-0055] [RUN-0058] [RUN-0069] [LDR-0160] a missing mandatory symbol is abi-invalid":
    let r = fresh()
    for s in ["name", "init", "destroy"]:
      checkpoint s
      # Through bindNative directly: registration already refuses these tables.
      let code = ModuleCode(
        kind: codeStatic,
        table: plainTable().without("logos_plain_consumer_MODULE_" & s).toTable,
      )
      let b = bindNative(code, "plain_consumer")
      check b.isErr and ("logos_plain_consumer_MODULE_" & s) in b.error
    check r.realizeFails(
      "no-dispatch", meterModuleStaticSymbols().without(meterDispatchSym)
    ).code == lecAbiInvalid

  test "[RUN-0057] [LDR-0100] a consumer-only module needs no provider symbol and has no call surface":
    reset()
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    let x = r.realize(staticRequest("c1", "plain_consumer", "plain")).tryGet
    check not x.binding.provider
    check x.record.callSurface.isNone and x.record.status == rsActive

  test "[RUN-0070] [LDR-0072] [LDR-0019] _MODULE_name() must return the expected module name":
    let r = fresh()
    check r.realizeFails(
      "other", plainTable(name = cast[pointer](otherName)), "plain_consumer"
    ).code == lecAbiInvalid
    check r.realizeFails(
      "null", plainTable(name = cast[pointer](nullName)), "plain_consumer"
    ).code == lecAbiInvalid
    # A registration for one module cannot realize another.
    r.registerStatic("meter", meterModuleStaticSymbols()).tryGet
    let x = r.realize(staticRequest("s1", "sensor_module", "meter"))
    check x.error.code == lecAbiInvalid

  test "[RUN-0056] [RUN-0071] [LDR-0073] [RUN-1086] the call surface is validated and every per-method function required":
    let r = fresh()
    let t = meterModuleStaticSymbols()
    check r.realizeFails(
      "garbage", t.replaced(meterSurface, cast[pointer](garbageSurface))
    ).code == lecAbiInvalid
    check r.realizeFails("null", t.replaced(meterSurface, cast[pointer](nullSurface))).code ==
      lecAbiInvalid
    check r.realizeFails("empty", t.replaced(meterSurface, cast[pointer](emptySurface))).code ==
      lecAbiInvalid
    check r.realizeFails(
      "sensor", t.replaced(meterSurface, cast[pointer](sensorSurface))
    ).code == lecAbiInvalid
    let missing = r.realizeFails("no-read", t.without(meterRead))
    check missing.code == lecAbiInvalid and meterRead in missing.message
    let extra = r.realizeFails(
      "extra", t & @[("logos_meter_module_CALL_meter_Write", cast[pointer](plainInit))]
    )
    check extra.code == lecAbiInvalid

  test "[RUN-0787] [RUN-0788] [RUN-0789] [RUN-0790] the optional _MODULE_async_api descriptor is probed and validated":
    let r = fresh()
    let t = meterModuleStaticSymbols()
    check r.realizeFails("bad-async", t & @[(meterAsync, cast[pointer](badAsyncApi))]).code ==
      lecAbiInvalid
    r.registerStatic("null-async", t & @[(meterAsync, cast[pointer](nullAsyncApi))]).tryGet
    let a = r.realize(staticRequest("n1", "meter_module", "null-async")).tryGet
    check a.binding.asyncApi == nil
    check r.release(a.id, "n1").isOk
    r.registerStatic("good-async", t & @[(meterAsync, cast[pointer](goodAsyncApi))]).tryGet
    let b = r.realize(staticRequest("g1", "meter_module", "good-async")).tryGet
    check b.binding.asyncApi == addr goodAsync
    check r.release(b.id, "g1").isOk

  test "[RUN-0072] [RUN-0082] [LDR-0080] one binding serves every instance; each call gets its own context":
    asyncCalls = 0
    let r = fresh()
    r.registerStatic(
      "meter", meterModuleStaticSymbols() & @[(meterAsync, cast[pointer](goodAsyncApi))]
    ).tryGet
    let a = r.realize(staticRequest("m1", "meter_module", "meter")).tryGet
    let b = r.realize(staticRequest("m2", "meter_module", "meter")).tryGet
    check asyncCalls == 1 # bound once
    check a.binding == b.binding and a.context != b.context
    check a.context != nil and b.context != nil
    check meterCall(a, 3).response ==
      diag("{\"label\": \"ch3\", \"reading\": {\"value\": 30}}")
    check meterCall(b, 4).status.isOk
    check r.release(a.id, "m1").isOk and r.release(b.id, "m2").isOk

# Realize --------------------------------------------------------------------------

suite "run.realizer: realize (LOADER §6, §7, §10) [IMPL]":
  test "[LDR-0074] [LDR-0075] [LDR-0076] [LDR-0077] [LDR-0078] [LDR-0039] [LDR-0041] [RUN-0073] the initialization input carries the services and the mapped state directory":
    reset()
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    let x = r.realize(
      staticRequest("c1", "plain_consumer", "plain", state = Opt.some("c1"))
    ).tryGet
    check outWasNull
    check seenInput.abiVersion == ModuleInitAbiVersion
    check seenInput.structSize == csize_t(sizeof(LogosModuleInitInput))
    check seenInput.runtimeControl == addr rcBinding
    check seenInput.publish == publishOp and
      seenInput.publishUserData == addr publishState
    check seenInput.invocationAccess.state == addr accessState
    check seenInput.configurationCbor == nil and seenInput.configurationCborLen == 0
    check seenStateDir == work / "state" / "c1" and dirExists(seenStateDir)
    when defined(posix):
      check getFilePermissions(seenStateDir) == {fpUserRead, fpUserWrite, fpUserExec}
    check x.stateDir == Opt.some(seenStateDir)
    # Without `state`, the absent representation.
    discard r.realize(staticRequest("c2", "plain_consumer", "plain")).tryGet
    check seenStateDir == ""

  test "[LDR-0076] a provider that declares events needs a publish binding":
    let r = fresh()
    r.registerStatic("meter", meterModuleStaticSymbols()).tryGet
    let x = r.realize(staticRequest("m1", "meter_module", "meter", publish = false))
    check x.error.code == lecRealizationFailed
    check r.liveCount == 0

  test "[LDR-0079] [LDR-0086] every result and context combination INTERFACE forbids fails, cleaned":
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    for (mode, destroyed) in [
      (imOkNull, 0), (imFail, 0), (imFailContext, 0), (imOkMessage, 1)
    ]:
      checkpoint $mode
      reset()
      initMode = mode
      let x = r.realize(staticRequest("c1", "plain_consumer", "plain"))
      check x.error.code == lecRealizationFailed
      check destroys == destroyed
      check r.liveCount == 0
    reset()
    initMode = imFail
    let f = r.realize(staticRequest("c1", "plain_consumer", "plain")).error
    check f.cause.get.code == ecModule and
      f.cause.get.message == Opt.some("cannot start")
    check "MODULE_ERROR" in f.message or "module" in f.message.toLowerAscii

  test "[LDR-0062] [LDR-0063] [LDR-0065] [LDR-0097] at most one realization per instance; the same request returns it":
    reset()
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    r.registerStatic("plain2", plainTable()).tryGet
    let a = r.realize(staticRequest("c1", "plain_consumer", "plain")).tryGet
    let again = r.realize(staticRequest("c1", "plain_consumer", "plain")).tryGet
    check again == a and inits == 1
    check r.realize(staticRequest("c1", "plain_consumer", "plain2")).error.code ==
      lecInstanceConflict
    check r.realize(
      staticRequest("c1", "plain_consumer", "plain", state = Opt.some("c1"))
    ).error.code == lecInstanceConflict
    # Released, the instance gets a fresh realization and context.
    check r.release(a.id, "c1").isOk
    let b = r.realize(staticRequest("c1", "plain_consumer", "plain")).tryGet
    check b.id != a.id and inits == 2 and destroys == 1

  test "[LDR-0045] [LDR-0149] [LDR-0062] [LDR-0065] the configuration handoff reaches _MODULE_init; another handoff is instance-conflict; a live one needs apply_configuration":
    reset()
    let blobs = liveConfigBlobs()
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    let bytes = tunerInput(tunerValue("handoff-station"), 3)
    let input = newBlob(bytes)
    let roots = fromRc(tunerCommitment()).tryGet
    proc request(revision: uint64, live = false): RealizeRequest =
      result = staticRequest("c1", "plain_consumer", "plain")
      result.configuration = Opt.some(
        ConfigurationHandoff(
          input: input, live: live, commitment: roots, valueRevision: revision
        )
      )

    let a = r.realize(request(3)).tryGet
    check seenInput.configurationCborLen == csize_t(bytes.len)
    check @(seenInput.configurationCbor.toOpenArray(0, bytes.high)) == bytes
    check r.realize(request(3)).tryGet == a and inits == 1
    let conflict = r.realize(request(4))
    check conflict.error.code == lecInstanceConflict
    check "handoff-station" notin conflict.error.message
    let status = r.getStatus("c1").tryGet
    check "handoff-station" notin $status
    check r.release(a.id, "c1").isOk
    # [SPEC LOADER §5.2; CONFIG §8] A live declaration without the hook.
    let live = r.realize(request(3, live = true))
    check live.error.code == lecAbiInvalid and inits == 1
    check "handoff-station" notin live.error.message
    drop(input)
    check liveConfigBlobs() == blobs

  test "[LDR-0018] [LDR-0024] [LDR-0130] semantically invalid requests are invalid-request":
    reset()
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    for (instance, module, binding, state) in [
      ("", "plain_consumer", "plain", Opt.none(string)),
      ('i'.repeat(129), "plain_consumer", "plain", Opt.none(string)),
      ("c1", "Plain", "plain", Opt.none(string)),
      ("c1", "a_call_b", "plain", Opt.none(string)),
      ("c1", "plain_consumer", "", Opt.none(string)),
      ("c1", "plain_consumer", "unknown", Opt.none(string)),
      ("c1", "plain_consumer", "plain", Opt.some("../x")),
      ("c1", "plain_consumer", "plain", Opt.some("")),
    ]:
      checkpoint instance & " " & module & " " & binding & " " & $state
      check r.realize(staticRequest(instance, module, binding, state)).error.code ==
        lecInvalidRequest
    check inits == 0
    var d = RealizeRequest(
      moduleInstance: "d1",
      descriptor: RealizationDescriptor(
        strategy: stDirectDynamic,
        module: "meter_module",
        artifact: ArtifactRecord(
          id: "meter", localPath: "https://example.org/meter.so", hashSuite: HashSuiteId
        ),
      ),
      services: services(),
    )
    check r.realize(d).error.code == lecInvalidRequest
    d.descriptor.artifact.localPath = "/nonexistent"
    d.descriptor.artifact.hashSuite = "logos.hash-suite.sha256"
    check r.realize(d).error.code == lecInvalidRequest

  test "[LDR-0067] [LDR-0068] [LDR-0035] hosted_dynamic is not advertised and is refused before anything is read":
    let r = fresh()
    let c = r.capabilities
    check c.directStatic and c.directDynamic
    check c.hostedPlacements.len == 0 and not c.forceRelease
    let x = r.realize(
      RealizeRequest(
        moduleInstance: "h1",
        descriptor: RealizationDescriptor(
          strategy: stHostedDynamic,
          module: "meter_module",
          placement: "process",
          artifact: ArtifactRecord(
            id: "meter", localPath: "/nonexistent", hashSuite: HashSuiteId
          ),
        ),
        services: services(),
      )
    )
    check x.error.code == lecUnsupportedStrategy

  test "[LDR-0165] [LDR-0089] a state mapping it cannot establish is realization-failed":
    reset()
    let r = newRealizer(work) # no state root
    r.registerStatic("plain", plainTable()).tryGet
    let x = r.realize(staticRequest("c1", "plain_consumer", "plain", Opt.some("c1")))
    check x.error.code == lecRealizationFailed and inits == 0

# Release and status ---------------------------------------------------------------

suite "run.realizer: live configuration (LOADER §8, §11) [IMPL]":
  test "[LDR-0113] [LDR-0135] [LDR-0136] apply runs the hook once through the retained context, excluded from release; a refusal invokes nothing":
    reset()
    let blobs = liveConfigBlobs()
    let r = fresh()
    r.registerStatic(
      "plain",
      plainTable() &
        @[
          ("logos_plain_consumer_MODULE_apply_configuration", cast[pointer](plainApply))
        ],
    ).tryGet
    let bytes = tunerInput(tunerValue("applied-station"), 5)
    let input = newBlob(bytes)
    let roots = fromRc(tunerCommitment()).tryGet
    proc request(instance: string, live: bool): RealizeRequest =
      result = staticRequest(instance, "plain_consumer", "plain")
      result.configuration = Opt.some(
        ConfigurationHandoff(
          input: input, live: live, commitment: roots, valueRevision: 4
        )
      )

    let x = r.realize(request("c1", live = true)).tryGet
    check x.live and x.initCommitment == Opt.some(roots)
    check r.applyConfiguration("r-unknown", "c1", input).error.code ==
      lecRealizationNotFound
    check r.applyConfiguration(x.id, "c2", input).error.code == lecRealizationNotFound
    check applies == 0
    check r.applyConfiguration(x.id, "c1", input).isOk
    check applies == 1 and seenApply == bytes
    # A valid rejection leaves the realization active; its status stays with
    # the Loader's error, for the Runtime's diagnostics only.
    applyResult = LogosResult(code: CErrorCode(ord(ecNotReady)), message: "not now")
    let rejected = r.applyConfiguration(x.id, "c1", input)
    check rejected.error.code == lecConfigurationRejected
    check rejected.error.cause.get.code == ecNotReady
    check "applied-station" notin rejected.error.message
    check r.getStatus("c1").tryGet.status == rsActive
    # While the hook runs: no second application, no release.
    check r.beginApply(x.id, "c1").isOk
    check r.beginApply(x.id, "c1").error.code == lecInvalidRequest
    check r.release(x.id, "c1").error.code == lecInvalidRequest
    check destroys == 0
    # An invalid result: realization-failed, the realization failed and still
    # owned until its release.
    applyResult = LogosResult(message: "fine")
    check r.completeApply("c1", applyResult).error.code == lecRealizationFailed
    let status = r.getStatus("c1").tryGet
    check status.status == rsFailed
    check status.failure.get.code == lecRealizationFailed
    check r.beginApply(x.id, "c1").error.code == lecInvalidRequest
    check r.release(x.id, "c1").isOk and destroys == 1
    # A result the Runtime no longer waits for is realization-failed too.
    let y = r.realize(request("c1", live = true)).tryGet
    check r.beginApply(y.id, "c1").isOk
    check r.completeApply("c1", LogosResult(), established = false).error.code ==
      lecRealizationFailed
    check r.release(y.id, "c1").isOk
    # A realization whose handoff did not declare live reconfiguration.
    let z = r.realize(request("c2", live = false)).tryGet
    check not z.live
    check r.applyConfiguration(z.id, "c2", input).error.code == lecInvalidRequest
    check applies == 2
    check r.release(z.id, "c2").isOk
    drop(input)
    check liveConfigBlobs() == blobs

suite "run.realizer: release and status (LOADER §7, §9, §11) [IMPL]":
  test "[LDR-0117] [LDR-0119] [LDR-0138] [LDR-0124] release destroys the context exactly once":
    reset()
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    let x = r.realize(staticRequest("c1", "plain_consumer", "plain")).tryGet
    check r.release(x.id, "c1").isOk
    check destroys == 1 and x.context == nil and r.liveCount == 0
    check r.release(x.id, "c1").isOk # idempotent
    check destroys == 1
    check r.release("r-unknown", "c9").isOk

  test "[LDR-0122] [LDR-0123] [LDR-0120] [LDR-0121] a mismatched pair or force leaves the record alone":
    reset()
    let r = fresh()
    r.registerStatic("plain", plainTable()).tryGet
    let a = r.realize(staticRequest("c1", "plain_consumer", "plain")).tryGet
    let b = r.realize(staticRequest("c2", "plain_consumer", "plain")).tryGet
    check r.release(a.id, "c2").error.code == lecRealizationNotFound
    check r.release(a.id, "c1", force = true).error.code == lecInvalidRequest
    check destroys == 0 and r.liveCount == 2
    check r.getStatus("c1").tryGet.realization == a.id
    check r.release(a.id, "c1").isOk and r.release(b.id, "c2").isOk

  test "[LDR-0104] [LDR-0105] [LDR-0106] [LDR-0107] [LDR-0108] [LDR-0109] [LDR-0099] [LDR-0098] get_status returns the instance's complete record":
    let r = fresh()
    r.registerStatic("meter", meterModuleStaticSymbols()).tryGet
    let x = r.realize(staticRequest("m1", "meter_module", "meter")).tryGet
    let s = r.getStatus("m1").tryGet
    check s.realization == x.id and s.moduleInstance == "m1" and s.status == rsActive
    var n: csize_t
    let p = cast[ModuleCallSurfaceFn](meterModuleStaticSymbols().filterIt(
      it[0] == meterSurface
    )[0][1])(addr n)
    check s.callSurface ==
      Opt.some(@(cast[ptr UncheckedArray[uint8]](p).toOpenArray(0, int(n) - 1)))
    check r.getStatus("m1", Opt.some(x.id)).isOk
    check r.getStatus("m1", Opt.some("r-other")).error.code == lecRealizationNotFound
    check r.getStatus("m9").error.code == lecRealizationNotFound
    check r.getStatus("m9", Opt.some(x.id)).error.code == lecRealizationNotFound
    check r.liveCount == 1
    check r.release(x.id, "m1").isOk

# Dynamic libraries ----------------------------------------------------------------

let
  meterLib = buildKitLibrary("meter_impl.nim", "rzmeter")
  markerLib = buildKitLibrary("load_marker.nim", "rzmarker")

proc digestOfFile(path: string): array[32, byte] =
  var h: Blake3Hasher
  h.init()
  let bytes = readFile(path)
  h.update(bytes.toOpenArrayByte(0, bytes.high))
  h.finish()

proc dynamicRequest(
    instance, module, path: string, hash: array[32, byte]
): RealizeRequest =
  RealizeRequest(
    moduleInstance: instance,
    descriptor: RealizationDescriptor(
      strategy: stDirectDynamic,
      module: module,
      artifact:
        ArtifactRecord(id: module, localPath: path, hash: hash, hashSuite: HashSuiteId),
    ),
    services: services(),
  )

suite "run.realizer: verified dynamic libraries (RUNTIME §2.1, §3.6; LOADER §3, §12) [IMPL]":
  test "[LDR-0025] [LDR-0026] [LDR-0141] [RUN-0133] [RUN-0068] a verified copy in a private directory is mapped and bound":
    let r = fresh()
    let x = r.realize(
      dynamicRequest("d1", "meter_module", meterLib, digestOfFile(meterLib))
    ).tryGet
    check x.binding.provider
    check meterCall(x, 5).response ==
      diag("{\"label\": \"ch5\", \"reading\": {\"value\": 50}}")
    let dirs = toSeq(walkDirs(work / "lcn-artifacts-*"))
    check dirs.len == 1
    let copies = toSeq(walkFiles(dirs[0] / "*"))
    check copies.len == 1
    when defined(posix):
      check getFilePermissions(dirs[0]) == {fpUserRead, fpUserWrite, fpUserExec}
      check getFilePermissions(copies[0]) == {fpUserRead, fpUserExec}
    check digestOfFile(copies[0]) == digestOfFile(meterLib)
    # [RUN-0135] [RUN-0136] A second instance reuses the verified binding.
    let y = r.realize(
      dynamicRequest("d2", "meter_module", meterLib, digestOfFile(meterLib))
    ).tryGet
    check y.binding == x.binding and y.context != x.context
    check toSeq(walkFiles(dirs[0] / "*")).len == 1
    check r.release(x.id, "d1").isOk and r.release(y.id, "d2").isOk

  test "[LDR-0025] [LDR-0141] [RUN-0131] bytes that do not match the digest are never mapped":
    let marker = work / "marker"
    removeFile(marker)
    putEnv("LCN_LOAD_MARKER", marker)
    let r = fresh()
    var wrong = digestOfFile(markerLib)
    wrong[0] = wrong[0] xor 1
    let bad = r.realize(dynamicRequest("k1", "marker_module", markerLib, wrong))
    check bad.error.code == lecArtifactIntegrityFailed
    check markerLib notin bad.error.message
    check not fileExists(marker)
    # The same library with its own digest is mapped (its load-time code runs)
    # and then refused: it exports no module ABI.
    let good = r.realize(
      dynamicRequest("k1", "marker_module", markerLib, digestOfFile(markerLib))
    )
    check good.error.code == lecAbiInvalid
    check fileExists(marker)
    delEnv("LCN_LOAD_MARKER")

  test "[RUN-0137] [RUN-0131] a changed digest pin is a fresh acceptance: the binding cached under the old pin is not used for it":
    let r = fresh()
    let pin = digestOfFile(meterLib)
    let x = r.realize(dynamicRequest("p1", "meter_module", meterLib, pin)).tryGet
    var changed = pin
    changed[0] = changed[0] xor 1
    let refused = r.realize(dynamicRequest("p2", "meter_module", meterLib, changed))
    check refused.error.code == lecArtifactIntegrityFailed
    check r.liveCount == 1
    # The old pin is still accepted, and its binding reused.
    let y = r.realize(dynamicRequest("p2", "meter_module", meterLib, pin)).tryGet
    check y.binding == x.binding
    check r.release(x.id, "p1").isOk and r.release(y.id, "p2").isOk

  test "[LDR-0132] a missing artifact is artifact-unavailable and the message names no path":
    let r = fresh()
    let path = work / "missing" / "libnothing.so"
    let x =
      r.realize(dynamicRequest("u1", "meter_module", path, digestOfFile(meterLib)))
    check x.error.code == lecArtifactUnavailable
    check path notin x.error.message and work notin x.error.message

  test "[LDR-0144] [SEC-0021] [PKG-0220] a staging control it cannot establish is realization-failed; an unreadable source stays artifact-unavailable":
    # [SPEC LOADER l.628, l.622; C-08, I88] The private copy is the control that
    # maps the verified bytes without a path-replacement gap (l.214). Code runs
    # only from that verified copy, never from the source path (PKG-0220).
    when defined(posix):
      if geteuid() == 0:
        skip() # root writes through 0500
      else:
        let r = fresh()
        let before = toSeq(walkDirs(work / "lcn-artifacts-*"))
        let first = r.realize(
          dynamicRequest("c1", "meter_module", meterLib, digestOfFile(meterLib))
        ).tryGet
        var dir = ""
        for d in walkDirs(work / "lcn-artifacts-*"):
          if d notin before:
            dir = d
        check dir.len > 0
        # Another library needs another staged copy, which cannot be written.
        setFilePermissions(dir, {fpUserRead, fpUserExec})
        let refused = r.realize(
          dynamicRequest("c2", "marker_module", markerLib, digestOfFile(markerLib))
        )
        setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
        check refused.isErr
        check refused.error.code == lecRealizationFailed
        check markerLib notin refused.error.message and work notin refused.error.message
        # A source that cannot be read is still artifact-unavailable.
        let gone = r.realize(
          dynamicRequest(
            "c3",
            "marker_module",
            work / "gone" & LibraryExtension,
            digestOfFile(markerLib),
          )
        )
        check gone.error.code == lecArtifactUnavailable
        # The staging failure is not cached: once the control can be
        # established the library is staged and mapped, and refused only for
        # exporting no module ABI.
        let again = r.realize(
          dynamicRequest("c2", "marker_module", markerLib, digestOfFile(markerLib))
        )
        check again.error.code == lecAbiInvalid
        check r.release(first.id, "c1").isOk
    else:
      skip()

# Tests leave realizations active, and one fake returns a context with MODULE_ERROR
# that nothing may destroy. Their contexts are freed here, after every suite has run,
# so LeakSanitizer reports only leaks of the code under test.
for c in contexts:
  deallocShared(c)
contexts.setLen(0)
