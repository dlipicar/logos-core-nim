## lcn-gen's module kit [IMPL]: a module written in Nim (`tests/kit/`) exports
## the INTERFACE §2.6 identity, lifecycle and provider symbols, and an ABI
## caller that knows only those C symbols gets what §2.6-§2.8 promise. Every
## call goes through the exported C functions; their results are checked with
## the ABI caller's own rules (`abi/checks`).

import std/typedthreads
import unittest2
import ../src/logos_core/cbor
import ../src/logos_core/iface/[accept, provider]
import ./support/[kitruntime, specdata]
import ./generated/meter_module_kit
import ./kit/[meter_impl, sensor_impl]

# The exported symbols, as an ABI caller declares them -------------------------------

proc meterName(): cstring {.
  importc: "logos_meter_module_MODULE_name", cdecl, gcsafe, raises: []
.}

proc meterInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.importc: "logos_meter_module_MODULE_init", cdecl, gcsafe, raises: [].}

proc meterDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_meter_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc meterCallSurface(
  outLen: ptr csize_t
): ptr uint8 {.
  importc: "logos_meter_module_MODULE_call_surface", cdecl, gcsafe, raises: []
.}

proc meterFree(
  module: ptr LogosModuleContext, p: pointer
) {.importc: "logos_meter_module_MODULE_free", cdecl, gcsafe, raises: [].}

proc meterDispatch(
  module: ptr LogosModuleContext,
  methodName: cstring,
  params: ptr UncheckedArray[uint8],
  paramsLen: csize_t,
  outResponse: ptr ptr UncheckedArray[uint8],
  outResponseLen: ptr csize_t,
): LogosResult {.
  importc: "logos_meter_module_MODULE_dispatch", cdecl, gcsafe, raises: []
.}

proc sensorInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.importc: "logos_sensor_module_MODULE_init", cdecl, gcsafe, raises: [].}

proc sensorDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_sensor_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc sensorDispatch(
  module: ptr LogosModuleContext,
  methodName: cstring,
  params: ptr UncheckedArray[uint8],
  paramsLen: csize_t,
  outResponse: ptr ptr UncheckedArray[uint8],
  outResponseLen: ptr csize_t,
): LogosResult {.
  importc: "logos_sensor_module_MODULE_dispatch", cdecl, gcsafe, raises: []
.}

proc sensorFree(
  module: ptr LogosModuleContext, p: pointer
) {.importc: "logos_sensor_module_MODULE_free", cdecl, gcsafe, raises: [].}

# Calling helpers ------------------------------------------------------------------------

proc newMeter(i: LogosModuleInitInput): ptr LogosModuleContext {.gcsafe.} =
  var i = i
  var ctx: ptr LogosModuleContext = nil
  let r = meterInit(addr i, addr ctx)
  doAssert checkOutcome(r, contextShape(ctx)).isOk, "meter init failed"
  ctx

proc meterCall(
    ctx: ptr LogosModuleContext, bare: string, params: openArray[byte]
): Call {.gcsafe.} =
  call(meterDispatch, meterFree, ctx, bare, params)

proc read(channel: uint32): seq[byte] =
  encode(MeterReadRequest(channel: channel)).get

proc decoded(c: Call): MeterReadResponse =
  MeterReadResponse.decode(c.response).get

template withInstance(ctx: ptr LogosModuleContext, T: typedesc, name, body: untyped) =
  ## The author's instance behind a kit context (white-box: tests only),
  ## borrowed: the kit's `GC_ref` keeps it alive.
  block:
    let name {.cursor.} = cast[T](instanceOf(ctx))
    body

# Tests ------------------------------------------------------------------------------------

suite "ifc.kit: module identity and the call surface (INTERFACE §2.6) [IMPL]":
  test "[IFC-0194] [IFC-0195] [IFC-0224] [IFC-0262] the module name is one static string":
    let a = meterName()
    check $a == "meter_module"
    check meterName() == a # the same static storage on every call
    let ctx = newMeter(input())
    check meterName() == a # an instance changes nothing
    meterDestroy(ctx)

  test "[IFC-0198] [IFC-0199] [IFC-0233] [IFC-0262] the call surface is the binding's descriptor, the same bytes every call":
    var n1, n2: csize_t
    let p1 = meterCallSurface(addr n1)
    let ctx = newMeter(input())
    let p2 = meterCallSurface(addr n2)
    meterDestroy(ctx)
    check p1 == p2 and n1 == n2 and n1 > 0
    let bytes = @(cast[ptr UncheckedArray[uint8]](p1).toOpenArray(0, int(n1) - 1))
    let b = acceptBinding(
      "meter_module", Opt.some(mirror("IFC/3.9.1.module.cddl")), [], []
    ).get
    check bytes == callSurfaceDescriptor(b).get
    let accepted = acceptCallSurfaceDescriptor(bytes, $meterName())
    check accepted.isOk

suite "ifc.kit: lifecycle (INTERFACE §2.6) [IMPL]":
  test "[IFC-0196] [IFC-0197] [IFC-0211] [IFC-0212] each initialization returns a distinct context; destroy runs the author's hook":
    let before = destroyed.load
    let a = newMeter(input())
    let b = newMeter(input())
    check a != nil and b != nil and a != b
    check instanceOf(a) != instanceOf(b)
    meterDestroy(a)
    meterDestroy(b)
    check destroyed.load == before + 2

  test "[IFC-0217] [IFC-0218] [IFC-0219] the state directory and configuration are copied, not retained":
    var dir = "/var/lib/meter"
    var config = diag("{\"rate\": 5}")
    let ctx = newMeter(input(stateDir = cstring(dir), configuration = config))
    dir[1] = 'X'
    config[0] = 0
    withInstance(ctx, Meter, m):
      check m.stateDir == Opt.some("/var/lib/meter")
      check m.configuration == Opt.some(diag("{\"rate\": 5}"))
    meterDestroy(ctx)

  test "[IFC-0222] a failed initialization returns a nonzero code and a null context":
    let refusing = @[0xF4'u8] # the author refuses CBOR `false`
    let notOneValue = @[0xFF'u8] # a break code: not one CBOR value
    # `input` borrows the configuration bytes, so they outlive each call.
    var i = input(configuration = refusing)
    var ctx = cast[ptr LogosModuleContext](addr rcState) # not null on purpose
    var r = meterInit(addr i, addr ctx)
    check ctx == nil
    let st = checkOutcome(r, contextShape(ctx))
    check st.isErr and st.error.code == ecModule
    check st.error.message == Opt.some("configuration says no")
    i = input()
    i.abiVersion = 1 # [SPEC INTERFACE §5.2] an older input
    r = meterInit(addr i, addr ctx)
    check ctx == nil and
      checkOutcome(r, contextShape(ctx)).error.code == ecVersionMismatch
    i = input()
    i.runtimeControl = nil
    r = meterInit(addr i, addr ctx)
    check ctx == nil and checkOutcome(r, contextShape(ctx)).error.code == ecModule
    i = input(configuration = notOneValue)
    r = meterInit(addr i, addr ctx)
    check ctx == nil and checkOutcome(r, contextShape(ctx)).error.code == ecInvalidParams

suite "ifc.kit: dispatch (INTERFACE §2.6, §2.7, §4.5, App A.3) [IMPL]":
  test "[IFC-0201] [IFC-0672] [IFC-0256] [IFC-0263] a call returns one response map that the instance's free releases":
    let ctx = newMeter(input())
    let c = meterCall(ctx, "read", read(4))
    check c.status.isOk
    check c.response == diag("{\"label\": \"ch4\", \"reading\": {\"value\": 40}}")
    check c.decoded.reading.value == 40
    meterFree(ctx, nil) # a no-op
    withInstance(ctx, Meter, m):
      check m.reads.load == 1
    meterDestroy(ctx)

  test "[IFC-0250] a rejected request never reaches the handler and leaves the outputs null":
    let ctx = newMeter(input())
    check meterCall(ctx, "write", read(1)).code == ecMethodNotFound
    check meterCall(ctx, "schema", diag("{}")).code == ecMethodNotFound # App A.3
    let malformed = meterCall(ctx, "read", @[0xA1'u8])
    check malformed.code == ecInvalidParams
    check malformed.status.error.detail ==
      Opt.some(invalidParamsDetail(iprMalformedCbor))
    let nondet = meterCall(
      ctx,
      "read",
      @[0xA1'u8, 0x67] & @(toOpenArrayByte("channel", 0, 6)) & @[0x18'u8, 0x04],
    )
    check nondet.code == ecInvalidParams
    check nondet.status.error.detail ==
      Opt.some(invalidParamsDetail(iprNonDeterministicCbor))
    let mismatch = meterCall(ctx, "read", diag("{\"channel\": \"four\"}"))
    check mismatch.code == ecInvalidParams
    check mismatch.status.error.detail ==
      Opt.some(invalidParamsDetail(iprSchemaMismatch, Opt.some(@[cbor("channel")])))
    check meterCall(ctx, "read", []).code == ecInvalidParams
    withInstance(ctx, Meter, m):
      check m.reads.load == 0
    meterDestroy(ctx)

  test "a handler's failure, an invalid response and an invalid failure":
    let ctx = newMeter(input())
    let failed = meterCall(ctx, "read", read(13))
    check failed.code == ecModule
    check failed.status.error.message == Opt.some("channel 13 is broken")
    let invalid = meterCall(ctx, "read", read(14)) # label outside 1..64 bytes
    check invalid.code == ecModule
    check invalid.response.len == 0
    let bogus = meterCall(ctx, "read", read(16)) # a failure with code OK
    check bogus.code == ecModule
    check bogus.status.error.message.isNone
    meterDestroy(ctx)

  test "[IFC-0206] a module with _implements dispatches its own and its interface's methods":
    var i = input(publish = false)
    var ctx: ptr LogosModuleContext = nil
    check checkOutcome(sensorInit(addr i, addr ctx), contextShape(ctx)).isOk
    let snap0 = call(sensorDispatch, sensorFree, ctx, "snapshot", diag("{}"))
    check snap0.status.isOk and snap0.response == diag("{\"count\": 0}")
    let conf = call(
      sensorDispatch,
      sensorFree,
      ctx,
      "configure",
      diag("{\"settings\": {\"kind\": \"sensor\", \"limit\": 9}}"),
    )
    check conf.status.isOk and conf.response == diag("{}")
    check call(
      sensorDispatch,
      sensorFree,
      ctx,
      "configure",
      diag("{\"settings\": {\"kind\": \"meter\", \"limit\": 9}}"),
    ).code == ecInvalidParams # the literal `kind`
    let snap1 = call(sensorDispatch, sensorFree, ctx, "snapshot", diag("{}"))
    check snap1.response == diag("{\"count\": 1}")
    withInstance(ctx, Sensor, sensor):
      check sensor.limit.load == 9
    sensorDestroy(ctx)

suite "ifc.kit: events and the invocation context (INTERFACE §2.5, §2.9.3, App A.4) [IMPL]":
  test "[IFC-0220] a typed publish helper encodes the event; a null callback is never called":
    ## A module whose call surface declares events refuses a null callback at
    ## `_MODULE_init` (`checkInitInput`), so the kit never holds one it could
    ## call; a module without events has no publish helper at all.
    withLock publishedLock:
      published.setLen(0)
    let ctx = newMeter(input())
    check meterCall(ctx, "read", read(15)).status.isOk
    withLock publishedLock:
      check published == @[("meter.changed_event", diag("{\"value\": 150}"), "plain")]
      published.setLen(0)
    meterDestroy(ctx)
    var i = input(publish = false)
    var quiet: ptr LogosModuleContext = nil
    let r = meterInit(addr i, addr quiet)
    check quiet == nil and checkOutcome(r, contextShape(quiet)).error.code == ecModule
    var si = input(publish = false)
    var sensor: ptr LogosModuleContext = nil
    check checkOutcome(sensorInit(addr si, addr sensor), contextShape(sensor)).isOk
    sensorDestroy(sensor)
    withLock publishedLock:
      check published.len == 0

  test "the caller, cancellation and scoped publication come from the current invocation":
    withLock publishedLock:
      published.setLen(0)
    let ctx = newMeter(input())
    check meterCall(ctx, "read", read(17)).code == ecNotReady # no provider entry
    var invocation =
      LogosInvocationContext(vtable: addr contextVtable, state: addr contextState)
    activeContext = addr invocation
    cancelled.store(true)
    let c = meterCall(ctx, "read", read(17))
    activeContext = nil
    cancelled.store(false)
    check c.status.isOk
    check c.decoded.label == consumerId
    check c.decoded.reading.label == Opt.some(runtimeId)
    check c.decoded.reading.value == 1 # cancelled
    withLock publishedLock:
      check published == @[("meter.changed_event", diag("{\"value\": 170}"), "scoped")]
      published.setLen(0)
    meterDestroy(ctx)

# Concurrency ---------------------------------------------------------------------------

const
  workers = 4
  rounds = 150

var
  sharedMeter: ptr LogosModuleContext
  concurrentFailures: Atomic[int]

proc worker(id: int) {.thread.} =
  ## Calls on one shared context from several threads at once (§2.8), plus the
  ## context-free symbols and an instance of the thread's own.
  let own = newMeter(input())
  for i in 0 ..< rounds:
    let channel = uint32(100 + id * rounds + i)
    let c = meterCall(sharedMeter, "read", read(channel))
    if c.status.isErr or
        MeterReadResponse.decode(c.response).get.label != "ch" & $channel:
      concurrentFailures += 1
    let f = meterCall(sharedMeter, "read", read(13))
    if f.status.isOk or f.status.error.message != Opt.some("channel 13 is broken"):
      concurrentFailures += 1
    if $meterName() != "meter_module":
      concurrentFailures += 1
    var n: csize_t
    if meterCallSurface(addr n) == nil or n == 0:
      concurrentFailures += 1
    if meterCall(own, "read", read(1)).status.isErr:
      concurrentFailures += 1
  meterDestroy(own)

suite "ifc.kit: concurrency (INTERFACE §2.7, §2.8) [IMPL]":
  test "[IFC-0259] [IFC-0265] [IFC-0266] [IFC-0267] [IFC-0268] [IFC-0269] [IFC-0271] [IFC-0272] [IFC-0273] [IFC-0274] [IFC-0286] calls on one context from several threads at once":
    sharedMeter = newMeter(input())
    var threads: array[workers, Thread[int]]
    for i in 0 ..< workers:
      createThread(threads[i], worker, i)
    joinThreads(threads)
    check concurrentFailures.load == 0
    withInstance(sharedMeter, Meter, m):
      check m.reads.load == workers * rounds * 2
    meterDestroy(sharedMeter)
