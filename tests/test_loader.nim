## The Module Loader as a module, through its contract (LOADER §4-§11; Tier 4b
## step 4b-1, DECISIONS I89): `loader/provider.nim` over `loader/core.nim`,
## called as the Runtime calls it, with a SYSTEM_SERVICE invocation context
## and the private handoffs in the side table (`support/loaderharness`).
##
## Target modules are the kit modules of `tests/kit/` linked into this suite
## and small hand-written modules that break one rule each or hold their
## `_MODULE_init` or `_MODULE_apply_configuration` until the test lets them
## go. The binder itself (static registration, symbol resolution, verified
## dynamic libraries) is `test_realizer`'s.

import std/[algorithm, locks, os, sequtils, strutils, times]
import unittest2
import ../src/logos_core/cbor
from ../src/logos_core/runtime/callside import nil
from ../src/logos_core/runtime/config import liveConfigBlobs
from ../src/logos_core/runtime/plumbing import CallTicket
import ../src/logos_core/iface/names
import ./support/[loaderharness, slowdown, tunerconfig]
from ./support/kitbuild import kitVariant
from ./support/kitruntime import rcBinding, publishOp, publishState
import ./kit/[meter_impl, sensor_impl]

let work = currentSourcePath().parentDir.parentDir / "build" / "loader" / kitVariant
removeDir(work)
createDir(work)

# Hand-written modules -----------------------------------------------------------------

type InitMode = enum
  imOk ## LOGOS_OK and a context
  imOkNull ## LOGOS_OK without a context
  imFail ## MODULE_ERROR with a message and no context
  imFailContext ## MODULE_ERROR that also returns a context
  imOkMessage ## LOGOS_OK, a context and a message

type Recorded = object
  ## Bytes a hook saw, in plain memory: the hooks run on other threads, whose
  ## seqs a refc heap cannot free.
  len: int
  data: array[1024, byte]

proc record(r: var Recorded, bytes: openArray[byte]) =
  doAssert bytes.len <= r.data.len
  r.len = bytes.len
  for i, b in bytes:
    r.data[i] = b

proc bytes(r: Recorded): seq[byte] =
  @(r.data.toOpenArray(0, r.len - 1))

proc text(r: Recorded): string =
  result = newString(r.len)
  for i in 0 ..< r.len:
    result[i] = char(r.data[i])

var
  initMode = imOk
  inits, destroys, applies: Atomic[int]
  orphans: array[16, Atomic[pointer]]
    ## contexts returned with a failure, which nothing may destroy (G250);
    ## plain memory, as the hooks run on other threads
  orphanCount: Atomic[int]
  outWasNull: bool
  seenInput: LogosModuleInitInput
  seenStateDir: Recorded
  seenConfiguration: Recorded
  seenTargetContext, seenLoaderContext: ptr LogosInvocationContext
  applyResult: LogosResult
  seenApply: Recorded
  holdInit, holdApply, entered: Atomic[bool]

proc waitWhile(flag: var Atomic[bool]) =
  ## Holds the calling thread while `flag` is set.
  while flag.load:
    sleep(1)

proc plainName(): cstring {.cdecl.} =
  "plain_consumer"

proc plainInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  entered.store(true)
  waitWhile(holdInit)
  discard inits.fetchAdd(1)
  {.cast(gcsafe).}:
    outWasNull = outContext[] == nil
    seenInput = input[]
    seenStateDir.len = 0
    if input.stateDir != nil:
      let dir = input.stateDir
      seenStateDir.record(toOpenArrayByte(dir, 0, int(dir.len) - 1))
    seenConfiguration.len = 0
    if input.configurationCbor != nil:
      seenConfiguration.record(
        input.configurationCbor.toOpenArray(0, int(input.configurationCborLen) - 1)
      )
    seenTargetContext = callside.currentOp(addr targetAccess)
    seenLoaderContext = callside.currentOp(addr loaderAccess)
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
    orphans[orphanCount.fetchAdd(1)].store(ctx)
  of imOkMessage:
    outContext[] = ctx
    result.message = "fine"

proc plainDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  discard destroys.fetchAdd(1)
  deallocShared(module)

proc plainApply(
    module: ptr LogosModuleContext, cbor: ptr UncheckedArray[uint8], len: csize_t
): LogosResult {.cdecl.} =
  entered.store(true)
  waitWhile(holdApply)
  discard applies.fetchAdd(1)
  {.cast(gcsafe).}:
    seenApply.record(cbor.toOpenArray(0, int(len) - 1))
    result = applyResult

proc reset() =
  initMode = imOk
  inits.store(0)
  destroys.store(0)
  applies.store(0)
  applyResult = LogosResult()
  seenApply.len = 0
  outWasNull = false
  seenInput = default(LogosModuleInitInput)
  seenStateDir.len = 0
  seenConfiguration.len = 0
  holdInit.store(false)
  holdApply.store(false)
  entered.store(false)

proc plainTable(apply = false): seq[(string, pointer)] =
  let c = projectModule("plain_consumer")
  result = @[
    ("logos_" & c & "_MODULE_name", cast[pointer](plainName)),
    ("logos_" & c & "_MODULE_init", cast[pointer](plainInit)),
    ("logos_" & c & "_MODULE_destroy", cast[pointer](plainDestroy)),
  ]
  if apply:
    result.add(
      ("logos_" & c & "_MODULE_apply_configuration", cast[pointer](plainApply))
    )

proc statics(): seq[StaticRegistration] =
  @[
    checkStaticRegistration("plain", plainTable()).tryGet,
    checkStaticRegistration("plain2", plainTable()).tryGet,
    checkStaticRegistration("plain-live", plainTable(apply = true)).tryGet,
    checkStaticRegistration("meter", meterModuleStaticSymbols()).tryGet,
    checkStaticRegistration("sensor", sensorModuleStaticSymbols()).tryGet,
  ]

var h: LoaderHarness
  ## The suite's Loader; every suite's teardown closes it, also after a
  ## failure.

proc open(stateRoot = Opt.some(work / "state")): LoaderHarness =
  reset()
  openHarness(statics(), work, stateRoot).tryGet

proc idOf(r: Realized): string =
  r.response.get.active.get.realization

proc codeOf(r: Realized): LoaderErrorCode =
  r.response.get.errorCode.get

proc failureOf(r: Realized): ErrorCode =
  r.response.error.code

# Calls from other threads ------------------------------------------------------------

type Job = object ## One Loader call on a thread of its own, in plain memory.
  at: LoaderCall
  bare: array[32, char]
  bareLen: int
  params: array[8192, byte]
  len: int
  ok: bool
  done: Atomic[bool]

proc runJob(j: ptr Job) {.thread.} =
  var bare = newString(j.bareLen)
  for i in 0 ..< j.bareLen:
    bare[i] = j.bare[i]
  let r = j.at.call(bare, j.params.toOpenArray(0, j.len - 1))
  j.ok = r.isOk
  j.done.store(true)

proc start(
    j: var Job, t: var Thread[ptr Job], at: LoaderCall, bare: string, params: seq[byte]
) =
  j.at = at
  j.bareLen = bare.len
  for i, c in bare:
    j.bare[i] = c
  j.len = params.len
  for i, b in params:
    j.params[i] = b
  j.done.store(false)
  createThread(t, runJob, addr j)

proc eventually(cond: proc(): bool {.gcsafe.}): bool =
  let until = getTime() + initDuration(milliseconds = 5000 * Slow)
  while getTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

# Suites -------------------------------------------------------------------------------

suite "ldr.module: capabilities (LOADER §4)":
  teardown:
    h.close()

  test "[LDR-0030] [LDR-0032] [LDR-0033] [LDR-0035] the direct strategies only, never force_release":
    h = open()
    let c = h.at.typed(
      "list_capabilities",
      LogosNSModuleLoaderListCapabilitiesRequest(),
      LogosNSModuleLoaderListCapabilitiesResponse,
    ).get.capabilities
    check c.direct_static == Opt.some(true) and c.direct_dynamic == Opt.some(true)
    check c.hosted_dynamic.isNone and c.force_release.isNone

suite "ldr.module: realize (LOADER §6, §7, §10)":
  teardown:
    h.close()

  test "[LDR-0059] [LDR-0060] [LDR-0074] [LDR-0075] [LDR-0076] [LDR-0077] [LDR-0078] [LDR-0039] [LDR-0041] [RUN-0073] [RUN-0198] [CFG-0067] [IFC-0221] [IFC-0484] the initialization input carries the private handoff and the mapped state directory":
    h = open()
    let x = h.realize("c1", "plain_consumer", "plain", state = Opt.some("c1"))
    check x.response.get.active.isSome
    check outWasNull
    check seenInput.abiVersion == ModuleInitAbiVersion
    check seenInput.structSize == csize_t(sizeof(LogosModuleInitInput))
    check seenInput.runtimeControl == addr rcBinding
    check seenInput.publish == publishOp and
      seenInput.publishUserData == addr publishState
    check seenInput.invocationAccess.state == addr targetAccess
    check seenInput.configurationCbor == nil and seenInput.configurationCborLen == 0
    let dir = seenStateDir.text
    check dir == work / "state" / "c1" and dirExists(dir)
    when defined(posix):
      check getFilePermissions(dir) == {fpUserRead, fpUserWrite, fpUserExec}
    check x.phase == Opt.some(fpNone)
    # Without `state`, the absent representation.
    check h.realize("c2", "plain_consumer", "plain").response.get.active.isSome
    check seenStateDir.len == 0

  test "[LDR-0098] [LDR-0099] [LDR-0100] [LDR-0020] [LDR-0052] [LDR-0053] [LDR-0102] a provider's record carries its exact call surface, a consumer's none; no direct record has an endpoint":
    h = open()
    let m = h.realize("m1", "meter_module", "meter").response.get.active.get
    var n: csize_t
    let p = cast[ModuleCallSurfaceFn](meterModuleStaticSymbols().filterIt(
      it[0] == "logos_meter_module_MODULE_call_surface"
    )[0][1])(addr n)
    check m.call_surface ==
      Opt.some(@(cast[ptr UncheckedArray[uint8]](p).toOpenArray(0, int(n) - 1)))
    check m.provider_endpoint.isNone and m.module_instance == "m1"
    let c = h.realize("c1", "plain_consumer", "plain").response.get.active.get
    check c.call_surface.isNone and c.provider_endpoint.isNone

  test "[LDR-0152] [IMPL-DECISION G250] the outbound handoff of an active realization is in the side table until its destroy has returned":
    h = open()
    let id = h.realize("m1", "meter_module", "meter").idOf
    let o = h.side.outbound(id)
    check o.isSome
    check o.get.dispatch != nil and o.get.free != nil and o.get.context != nil
    check o.get.declaresEvents
    check h.side.counts == (0, 1)
    check h.release(id, "m1").released
    check h.side.outbound(id).isNone and h.side.counts == (0, 0)

  test "[LDR-0076] a provider that declares events needs a publish binding":
    h = open()
    let x = h.realize("m1", "meter_module", "meter", publish = false)
    check x.codeOf == lecRealizationFailed
    check x.phase == Opt.some(fpNone)
    check h.liveCount == 0

  test "[LDR-0079] [LDR-0086] [RUN-0298] [RUN-0296] [IMPL-DECISION G250] every result and context combination INTERFACE forbids fails with phase init, cleaned; a context returned with a failure is never destroyed":
    h = open()
    for (mode, destroyed) in [
      (imOkNull, 0), (imFail, 0), (imFailContext, 0), (imOkMessage, 1)
    ]:
      checkpoint $mode
      reset()
      initMode = mode
      let x = h.realize("c1", "plain_consumer", "plain")
      check x.codeOf == lecRealizationFailed
      check x.phase == Opt.some(fpInit)
      check destroys.load == destroyed
      check h.liveCount == 0
      check h.status("c1").statusError == Opt.some(lecRealizationNotFound)
    reset()
    initMode = imFail
    let e = h.realize("c1", "plain_consumer", "plain").response.get.errorOf
    check e.message.isSome and "cannot start" notin e.message.get

  test "[LDR-0062] [LDR-0063] [LDR-0065] [LDR-0097] at most one realization per instance; the same request returns it":
    h = open()
    let a = h.realize("c1", "plain_consumer", "plain")
    let again = h.realize("c1", "plain_consumer", "plain")
    check again.idOf == a.idOf and inits.load == 1
    check h.realize("c1", "plain_consumer", "plain2").codeOf == lecInstanceConflict
    check h.realize("c1", "plain_consumer", "plain", state = Opt.some("c1")).codeOf ==
      lecInstanceConflict
    # Another private handoff is another request.
    var other = targetServices()
    other.publishUserData = addr inits
    check h.realizeAs(
      realizeRequest("c1", staticDescriptor("plain_consumer", "plain")), Opt.some(other)
    ).codeOf == lecInstanceConflict
    # Released, the instance gets a fresh realization and context.
    check h.release(a.idOf, "c1").released
    let b = h.realize("c1", "plain_consumer", "plain")
    check b.idOf != a.idOf and inits.load == 2 and destroys.load == 1

  test "[LDR-0044] [LDR-0045] [LDR-0149] [LDR-0062] [LDR-0065] the configuration handoff reaches _MODULE_init as the same bytes; another handoff is instance-conflict; a live one needs apply_configuration":
    h = open()
    let blobs = liveConfigBlobs()
    let bytes = tunerInput(tunerValue("handoff-station"), 3)
    proc request(
        revision: uint64, live = false, binding = "plain"
    ): LogosNSModuleLoaderRealizeRequest =
      result = realizeRequest("c1", staticDescriptor("plain_consumer", binding))
      result.configuration = Opt.some(
        LogosNSModuleLoaderConfigurationHandoff(
          input: LogosNSModuleConfigurationConfigurationInput.decode(
            tunerInput(tunerValue("handoff-station"), revision)
          ).get,
          live_reconfiguration: (if live: Opt.some(true) else: Opt.none(bool)),
        )
      )

    let a = h.realizeAs(request(3))
    check seenConfiguration.bytes == bytes
    check h.realizeAs(request(3)).idOf == a.idOf and inits.load == 1
    let conflict = h.realizeAs(request(4))
    check conflict.codeOf == lecInstanceConflict
    check "handoff-station" notin $conflict.response.get.errorOf
    check "handoff-station" notin $h.status("c1")
    check h.release(a.idOf, "c1").released
    # [SPEC LOADER §5.2; CONFIG §8] A live declaration without the hook.
    let live = h.realizeAs(request(3, live = true))
    check live.codeOf == lecAbiInvalid and inits.load == 1
    check "handoff-station" notin $live.response.get.errorOf
    h.close()
    check liveConfigBlobs() == blobs

  test "[LDR-0018] [LDR-0024] [LDR-0130] [LDR-0131] semantically invalid requests are invalid-request; one outside the schema is INVALID_PARAMS":
    h = open()
    for (instance, module, binding, state) in [
      ("c1", "Plain", "plain", Opt.none(string)),
      ("c1", "a_call_b", "plain", Opt.none(string)),
      ("c1", "plain_consumer", "unknown", Opt.none(string)),
      ("c1", "plain_consumer", "plain", Opt.some("../x")),
    ]:
      checkpoint instance & " " & module & " " & binding & " " & $state
      check h.realize(instance, module, binding, state).codeOf == lecInvalidRequest
    for (instance, module, binding, state) in [
      ("", "plain_consumer", "plain", Opt.none(string)),
      ('i'.repeat(129), "plain_consumer", "plain", Opt.none(string)),
      ("c1", "plain_consumer", "", Opt.none(string)),
      ("c1", "plain_consumer", "plain", Opt.some("")),
    ]:
      checkpoint instance & " " & module & " " & binding & " " & $state
      # Built by hand: the generated encoder refuses what is outside the schema.
      var request = @[
        (cbor("module_instance"), cbor(instance)),
        (
          cbor("descriptor"),
          cborMap(
            (cbor("strategy"), cbor("direct_static")),
            (cbor("module"), cbor(module)),
            (cbor("static_binding"), cborMap((cbor("binding"), cbor(binding)))),
          ),
        ),
      ]
      if state.isSome:
        request.add((cbor("state"), cborMap((cbor("assignment"), cbor(state.get)))))
      let r = h.at.call("realize", encodeCbor(cborMap(request)))
      check r.error.code == ecInvalidParams
    check inits.load == 0
    var d = LogosNSModuleLoaderRealizationDescriptor(
      kind: LogosNSModuleLoaderRealizationDescriptorKind.Direct_dynamic,
      arm_Direct_dynamic: LogosNSModuleLoaderRealizationDescriptorARDirectDynamicMap(
        module: "meter_module",
        artifact: LogosNSModuleLoaderArtifact(
          id: "meter",
          local_path: "https://example.org/meter.so",
          hash: newSeq[byte](32),
        ),
      ),
    )
    check h.realizeAs(realizeRequest("d1", d)).codeOf == lecInvalidRequest

  test "[LDR-0067] [LDR-0068] [LDR-0142] hosted_dynamic is not advertised and is refused before anything is read":
    h = open()
    let d = LogosNSModuleLoaderRealizationDescriptor(
      kind: LogosNSModuleLoaderRealizationDescriptorKind.Hosted_dynamic,
      arm_Hosted_dynamic: LogosNSModuleLoaderRealizationDescriptorARHostedDynamicMap(
        module: "meter_module",
        placement: LogosNSModuleLoaderHostedPlacement(
          kind: LogosNSModuleLoaderHostedPlacementKind.Process
        ),
        artifact: LogosNSModuleLoaderArtifact(
          id: "meter", local_path: "/nonexistent/meter.so", hash: newSeq[byte](32)
        ),
      ),
    )
    let x = h.realizeAs(realizeRequest("h1", d))
    check x.codeOf == lecUnsupportedStrategy
    check x.phase == Opt.some(fpNone)

  test "[LDR-0132] a missing artifact is artifact-unavailable and the message names no path":
    h = open()
    let path = work / "missing" / "meter.so"
    let d = LogosNSModuleLoaderRealizationDescriptor(
      kind: LogosNSModuleLoaderRealizationDescriptorKind.Direct_dynamic,
      arm_Direct_dynamic: LogosNSModuleLoaderRealizationDescriptorARDirectDynamicMap(
        module: "meter_module",
        artifact: LogosNSModuleLoaderArtifact(
          id: "meter", local_path: path, hash: newSeq[byte](32)
        ),
      ),
    )
    let x = h.realizeAs(realizeRequest("d1", d))
    check x.codeOf == lecArtifactUnavailable
    check path notin $x.response.get.errorOf and "missing" notin $x.response.get.errorOf

  test "[LDR-0165] [LDR-0089] [LDR-0038] [RUN-0847] a state mapping it cannot establish is realization-failed with no phase, before init":
    h = open(stateRoot = Opt.none(string))
    let x = h.realize("c1", "plain_consumer", "plain", Opt.some("c1"))
    check x.codeOf == lecRealizationFailed and inits.load == 0
    check x.phase == Opt.some(fpNone)

  test "[LDR-0088] [LDR-0148] a request with no private handoff from the Runtime is invalid-request":
    h = open()
    let x = h.realizeAs(
      realizeRequest("c1", staticDescriptor("plain_consumer", "plain")),
      services = Opt.none(InboundHandoff),
    )
    check x.codeOf == lecInvalidRequest and inits.load == 0
    check x.phase.isNone

suite "ldr.module: failed realizations kept (LOADER §7, §8, §9)":
  teardown:
    h.close()

  test "[LDR-0064] [LDR-0011] [LDR-0159] [LDR-0122] [LDR-0123] [LDR-0124] [LDR-0093] [LDR-0103] an indeterminate live configuration leaves a failed record: the same request returns it, another is instance-conflict, its release destroys once":
    h = open()
    let input = LogosNSModuleConfigurationConfigurationInput.decode(
      tunerInput(tunerValue("kept"), 2)
    ).get
    var req = realizeRequest("c1", staticDescriptor("plain_consumer", "plain-live"))
    req.configuration = Opt.some(
      LogosNSModuleLoaderConfigurationHandoff(
        input: input, live_reconfiguration: Opt.some(true)
      )
    )
    let id = h.realizeAs(req).idOf
    applyResult = LogosResult(message: "fine") # not a valid status
    let applied = h.at.typed(
      "apply_configuration",
      LogosNSModuleLoaderApplyConfigurationRequest(
        module_instance: "c1", realization: id, configuration: input
      ),
      LogosNSModuleLoaderApplyConfigurationResponse,
    ).get
    check applied.kind == LogosNSModuleLoaderApplyConfigurationResponseKind.Case2
    check applied.arm_2.realization.realization == id
    check codeOf(applied.arm_2.realization.failure.code) == lecRealizationFailed
    let s = h.status("c1").found.get
    check s.kind ==
      LogosNSModuleLoaderRealizationKind.logos_NS_module_loader_Failed_realization
    # The same request: the same failed record, no second init.
    let again = h.realizeAs(req).response.get
    check again.kind == LogosNSModuleLoaderRealizeResponseKind.Case2
    check again.arm_2.realization.realization == id and inits.load == 1
    # Another request for the instance.
    check h.realize("c1", "plain_consumer", "plain").codeOf == lecInstanceConflict
    check h.release(id, "c1").released and destroys.load == 1
    check h.status("c1").statusError == Opt.some(lecRealizationNotFound)

suite "ldr.module: the caller (LOADER l.80, l.426; RUNTIME l.1652-1667)":
  teardown:
    h.close()

  test "[LDR-0088] [IMPL-DECISION G251] a module caller, or a context naming none, is NOT_AUTHORISED for every method and changes nothing":
    h = open()
    let id = h.realize("m1", "meter_module", "meter").idOf
    let requests = [
      ("list_capabilities", encode(LogosNSModuleLoaderListCapabilitiesRequest()).get),
      (
        "realize",
        encode(realizeRequest("c9", staticDescriptor("plain_consumer", "plain"))).get,
      ),
      (
        "get_status",
        encode(LogosNSModuleLoaderGetStatusRequest(module_instance: "m1")).get,
      ),
      (
        "release",
        encode(
          LogosNSModuleLoaderReleaseRequest(module_instance: "m1", realization: id)
        ).get,
      ),
      (
        "apply_configuration",
        encode(
          LogosNSModuleLoaderApplyConfigurationRequest(
            module_instance: "m1",
            realization: id,
            configuration: LogosNSModuleConfigurationConfigurationInput.decode(
              tunerInput(tunerValue())
            ).get,
          )
        ).get,
      ),
    ]
    doAssert h.side.putInbound("c9", targetServices()).isOk
    for caller in [asModule, asNone]:
      for (bare, params) in requests:
        checkpoint $caller & " " & bare
        check h.at.call(bare, params, caller).error.code == ecNotAuthorised
    discard h.side.withdrawInbound("c9")
    check inits.load == 0 and destroys.load == 0 and h.liveCount == 1
    check h.status("m1").found.isSome

  test "[LDR-0131] a request that does not decode is INVALID_PARAMS, not a Loader error":
    h = open()
    for bare in ["realize", "release", "get_status", "apply_configuration"]:
      checkpoint bare
      check h.at.call(bare, [0xA1'u8, 0x61, 0x78, 0xFF]).error.code == ecInvalidParams

suite "ldr.module: status (LOADER §7, §11)":
  teardown:
    h.close()

  test "[LDR-0104] [LDR-0105] [LDR-0106] [LDR-0107] [LDR-0108] [LDR-0109] get_status returns the instance's complete record":
    h = open()
    let id = h.realize("m1", "meter_module", "meter").idOf
    let s = h.status("m1").found.get
    check s.kind ==
      LogosNSModuleLoaderRealizationKind.logos_NS_module_loader_Active_realization
    let a = s.arm_logos_NS_module_loader_Active_realization
    check a.realization == id and a.module_instance == "m1" and a.call_surface.isSome
    check h.status("m1", Opt.some(id)).found.isSome
    check h.status("m1", Opt.some("r-other")).statusError ==
      Opt.some(lecRealizationNotFound)
    check h.status("m9").statusError == Opt.some(lecRealizationNotFound)
    check h.status("m9", Opt.some(id)).statusError == Opt.some(lecRealizationNotFound)
    check h.liveCount == 1

  test "[LDR-0137] [LDR-0139] status during a realize held in its init is the record before; another instance completes meanwhile":
    h = open()
    holdInit.store(true)
    doAssert h.side.putInbound("c1", targetServices()).isOk
    var j: Job
    var t: Thread[ptr Job]
    j.start(
      t,
      h.at,
      "realize",
      encode(realizeRequest("c1", staticDescriptor("plain_consumer", "plain"))).get,
    )
    check eventually(
      proc(): bool =
        entered.load
    )
    check h.status("c1").statusError == Opt.some(lecRealizationNotFound)
    # Another instance is not held behind it: the Loader orders per instance.
    let m = h.realize("m1", "meter_module", "meter")
    check m.response.get.active.isSome
    check not j.done.load
    holdInit.store(false)
    joinThread(t)
    check j.ok
    discard h.side.withdrawInbound("c1")
    check h.status("c1").found.isSome
    check h.liveCount == 2
    discard h.realize("c1", "plain_consumer", "plain") # for the teardown

suite "ldr.module: live configuration (LOADER §8, §11)":
  teardown:
    h.close()

  test "[LDR-0111] [LDR-0112] [LDR-0113] [IFC-0213] apply runs the hook once through the retained context; a refusal invokes nothing":
    h = open()
    let input = LogosNSModuleConfigurationConfigurationInput.decode(
      tunerInput(tunerValue("applied-station"), 5)
    ).get
    proc request(instance: string, live: bool): LogosNSModuleLoaderRealizeRequest =
      result =
        realizeRequest(instance, staticDescriptor("plain_consumer", "plain-live"))
      result.configuration = Opt.some(
        LogosNSModuleLoaderConfigurationHandoff(
          input: input,
          live_reconfiguration: (if live: Opt.some(true) else: Opt.none(bool)),
        )
      )

    proc apply(instance, id: string): LogosNSModuleLoaderApplyConfigurationResponse =
      h.at.typed(
        "apply_configuration",
        LogosNSModuleLoaderApplyConfigurationRequest(
          module_instance: instance, realization: id, configuration: input
        ),
        LogosNSModuleLoaderApplyConfigurationResponse,
      ).get

    proc errorCode(r: LogosNSModuleLoaderApplyConfigurationResponse): LoaderErrorCode =
      doAssert r.kind == LogosNSModuleLoaderApplyConfigurationResponseKind.Case1
      codeOf(r.arm_1.error.code)

    let id = h.realizeAs(request("c1", live = true)).idOf
    check apply("c1", "r-unknown").errorCode == lecRealizationNotFound
    check apply("c2", id).errorCode == lecRealizationNotFound
    check applies.load == 0
    check apply("c1", id).kind == LogosNSModuleLoaderApplyConfigurationResponseKind.Case0
    check applies.load == 1 and seenApply.bytes == encode(input).get
    # A valid rejection leaves the realization active.
    applyResult = LogosResult(code: CErrorCode(ord(ecNotReady)), message: "not now")
    let rejected = apply("c1", id)
    check rejected.errorCode == lecConfigurationRejected
    check "applied-station" notin $rejected and "not now" notin $rejected
    check h.status("c1").found.get.kind ==
      LogosNSModuleLoaderRealizationKind.logos_NS_module_loader_Active_realization
    # A realization whose handoff did not declare live reconfiguration.
    let z = h.realizeAs(request("c2", live = false)).idOf
    check apply("c2", z).errorCode == lecInvalidRequest
    check applies.load == 2

  test "[LDR-0135] [LDR-0136] a release waits for an apply that is running on the same instance":
    h = open()
    let input = LogosNSModuleConfigurationConfigurationInput.decode(
      tunerInput(tunerValue("held"), 1)
    ).get
    var req = realizeRequest("c1", staticDescriptor("plain_consumer", "plain-live"))
    req.configuration = Opt.some(
      LogosNSModuleLoaderConfigurationHandoff(
        input: input, live_reconfiguration: Opt.some(true)
      )
    )
    let id = h.realizeAs(req).idOf
    holdApply.store(true)
    entered.store(false)
    var ja, jr: Job
    var ta, tr: Thread[ptr Job]
    ja.start(
      ta,
      h.at,
      "apply_configuration",
      encode(
        LogosNSModuleLoaderApplyConfigurationRequest(
          module_instance: "c1", realization: id, configuration: input
        )
      ).get,
    )
    check eventually(
      proc(): bool =
        entered.load
    )
    jr.start(
      tr,
      h.at,
      "release",
      encode(LogosNSModuleLoaderReleaseRequest(module_instance: "c1", realization: id)).get,
    )
    sleep(int(50 * Slow))
    check not jr.done.load and destroys.load == 0
    holdApply.store(false)
    joinThread(ta)
    joinThread(tr)
    check ja.ok and jr.ok
    check applies.load == 1 and destroys.load == 1
    check h.status("c1").statusError == Opt.some(lecRealizationNotFound)

suite "ldr.module: release (LOADER §9, §11)":
  teardown:
    h.close()

  test "[LDR-0115] [LDR-0116] [LDR-0117] [LDR-0119] [LDR-0138] [IFC-0214] release destroys the context exactly once; again, or an unknown id, succeeds":
    h = open()
    let id = h.realize("c1", "plain_consumer", "plain").idOf
    check h.release(id, "c1").released
    check destroys.load == 1 and h.liveCount == 0
    check h.release(id, "c1").released # idempotent
    check destroys.load == 1
    check h.release("r-unknown", "c9").released

  test "[LDR-0122] [LDR-0123] [LDR-0120] [LDR-0121] a mismatched pair or force leaves the record alone":
    h = open()
    let a = h.realize("c1", "plain_consumer", "plain").idOf
    let b = h.realize("c2", "plain_consumer", "plain").idOf
    check h.release(a, "c2").releaseError == Opt.some(lecRealizationNotFound)
    check h.release(a, "c1", force = Opt.some(true)).releaseError ==
      Opt.some(lecInvalidRequest)
    check destroys.load == 0 and h.liveCount == 2
    check h.status("c1", Opt.some(a)).found.isSome
    check h.release(a, "c1").released
    check h.release(b, "c2").released

suite "ldr.module: errors (LOADER §10)":
  teardown:
    h.close()

  test "[LDR-0127] [LDR-0128] the codes it can produce are the contract's, as data":
    var produced: seq[string]
    for c in LoaderErrorCode:
      produced.add $c
    var declared: seq[string]
    for k in LogosNSModuleLoaderErrorCodeKind:
      declared.add(($k).toLowerAscii.replace('_', '-'))
    check produced.sorted == declared.sorted

suite "ldr.module: the invocation context and cancellation (INTERFACE l.2170; LOADER l.633-634)":
  teardown:
    h.close()

  test "[IFC-0484] a target's _MODULE_init sees no invocation context of the Loader's call":
    h = open()
    seenTargetContext = cast[ptr LogosInvocationContext](1)
    seenLoaderContext = cast[ptr LogosInvocationContext](1)
    check h.realize("c1", "plain_consumer", "plain").response.get.active.isSome
    check seenTargetContext == nil and seenLoaderContext == nil

  test "[LDR-0086] a realize cancelled before _MODULE_init fails CANCELLED and creates nothing":
    h = open()
    let ticket = createShared(CallTicket)
    initLock(ticket.lock)
    ticket.cancelled.store(true)
    doAssert h.side.putInbound("c1", targetServices()).isOk
    let r = h.at.call(
      "realize",
      encode(realizeRequest("c1", staticDescriptor("plain_consumer", "plain"))).get,
      ticket = ticket,
    )
    check r.error.code == ecCancelled
    check inits.load == 0 and h.liveCount == 0
    discard h.side.withdrawInbound("c1")
    check h.status("c1").statusError == Opt.some(lecRealizationNotFound)
    # Not cancelled, the same instance realizes.
    check h.realize("c1", "plain_consumer", "plain").response.get.active.isSome
    deinitLock(ticket.lock)
    freeShared(ticket)

suite "ldr.module: wiring (LOADER l.676-677; BCP l.287)":
  teardown:
    h.close()

  test "[LDR-0148] [IMPL-DECISION G246] an instance with no protected wiring does not start; the Loader cannot be wired to realize itself":
    let boot = newRealizer(work)
    boot.registerStatic(loaderStaticRegistration()).tryGet
    var rc = rcBinding
    let x = boot.realize(
      RealizeRequest(
        moduleInstance: LoaderInstanceId,
        descriptor: RealizationDescriptor(
          strategy: stDirectStatic, module: LoaderModuleName, binding: LoaderBindingId
        ),
        services: InitServices(
          runtimeControl: addr rc,
          publish: publishOp,
          publishUserData: addr publishState,
          invocationAccess:
            LogosInvocationAccess(state: addr loaderAccess, current: callside.currentOp),
        ),
      )
    )
    check x.error.code == lecRealizationFailed
    check x.error.cause.get.code == ecModule
    let side = newSideTable()
    check wireLoader(
      addr rc,
      LoaderWiring(statics: @[loaderStaticRegistration()], workDir: work, side: side),
    ).isErr
    freeSideTable(side)

# One fake returns a context with MODULE_ERROR that nothing may destroy (G250; I88
# deviation 2). Those contexts are freed here, after every suite has run, so
# LeakSanitizer reports only leaks of the code under test.
for i in 0 ..< orphanCount.load:
  deallocShared(orphans[i].load)
