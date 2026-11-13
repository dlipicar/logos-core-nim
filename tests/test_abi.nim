## INTERFACE §2.4, §2.6, §2.7.1, §2.9, §5.2: the native ABI structs as Nim
## types (layout compared with the generated `logos_types.h` through the host C
## compiler) and the checks each side applies to what the other hands it.

import std/[os, osproc, strutils]
import unittest2
import ../src/logos_core/abi/checks
from ../src/logos_core/iface/cmap import logosTypesHeader
from ../src/logos_core/codegen/hostgen import logosRuntimeHeader
import ../src/logos_core/abi/host
from ../src/logos_core/runtime/config import
  ValueRecord, SchemaRoots, Provenance, newBlob, drop, encodeInput

const deviceTarget = defined(android) or defined(ios)
  ## No C compiler where a cross-compiled suite runs; the layout test is SKIPPED
  ## there and the host suites compare every struct.

const outDir = "build/codegen/abi"

# Stub operations ---------------------------------------------------------------------

var calls = 0 ## bumped by every stub: a check must never call through what it checks

proc stub() {.cdecl.} =
  inc calls

let stubAddr = cast[pointer](stub)
  ## Cast through a runtime pointer: a direct proc-to-proc cast reaches the C
  ## compiler as an incompatible function-pointer assignment.

proc procOnly[P: proc](p: P) =
  ## Matches only procedure types: `when compiles(procOnly(f))` selects a
  ## struct's operation fields.
  discard

proc armed[T](v: T): T =
  ## `v` with every operation set to the counting stub.
  result = v
  for f in fields(result):
    when compiles(procOnly(f)):
      f = cast[typeof(f)](stubAddr)

proc opNames[T](v: T): seq[string] =
  for n, f in fieldPairs(v):
    when compiles(procOnly(f)):
      result.add n

proc nulled[T](v: T, k: int): T =
  ## `v` with its `k`th operation null.
  result = v
  var i = 0
  for f in fields(result):
    when compiles(procOnly(f)):
      if i == k:
        f = nil
      inc i

proc code(r: AbiCheck): ErrorCode =
  if r.isOk: ecOk else: r.error.code

var stateByte: byte
let somewhere = cast[pointer](addr stateByte)

proc rcVtable(): LogosRuntimeControlVtable =
  armed(
    LogosRuntimeControlVtable(
      abiVersion: 2, structSize: csize_t(sizeof(LogosRuntimeControlVtable))
    )
  )

proc routeVtable(): LogosRouteVtable =
  armed(LogosRouteVtable(abiVersion: 2, structSize: csize_t(sizeof(LogosRouteVtable))))

proc ctxVtable(): LogosInvocationContextVtable =
  armed(
    LogosInvocationContextVtable(
      abiVersion: 1, structSize: csize_t(sizeof(LogosInvocationContextVtable))
    )
  )

proc callVtable(): LogosAsyncCallVtable =
  armed(
    LogosAsyncCallVtable(
      abiVersion: 1, structSize: csize_t(sizeof(LogosAsyncCallVtable))
    )
  )

proc bytesOf(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

template dataOf(b: seq[byte]): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](unsafeAddr b[0])

# Layout ------------------------------------------------------------------------------

proc snake(nimName: string): string =
  for c in nimName:
    if c in {'A' .. 'Z'}:
      result.add '_'
      result.add toLowerAscii(c)
    else:
      result.add c

proc describe[T](cName: string, sample: T): seq[(string, string)] =
  ## One `printf` per fact about `T`: its size and alignment, then each field's
  ## offset, with the value Nim computes for it.
  var x = sample
  result.add (
    "printf(\"" & cName & " size %zu align %zu\\n\", sizeof(" & cName & "), _Alignof(" &
      cName & "));",
    cName & " size " & $sizeof(T) & " align " & $alignof(T),
  )
  for n, f in fieldPairs(x):
    let off = cast[int](addr f) - cast[int](addr x)
    let c = snake(n)
    result.add (
      "printf(\"" & cName & "." & c & " %zu\\n\", offsetof(" & cName & ", " & c & "));",
      cName & "." & c & " " & $off,
    )

proc layoutFacts(): seq[(string, string)] =
  result.add describe("logos_result_t", LogosResult())
  result.add describe("logos_response_owner_t", LogosResponseOwner())
  result.add describe("logos_utf8_view_t", LogosUtf8View())
  result.add describe("logos_caller_view_t", LogosCallerView())
  result.add describe("logos_invocation_context_t", LogosInvocationContext())
  result.add describe(
    "logos_invocation_context_vtable_t", LogosInvocationContextVtable()
  )
  result.add describe("logos_invocation_access_t", LogosInvocationAccess())
  result.add describe("logos_async_options_t", LogosAsyncOptions())
  result.add describe("logos_async_callbacks_t", LogosAsyncCallbacks())
  result.add describe("logos_async_call_t", LogosAsyncCall())
  result.add describe("logos_async_call_vtable_t", LogosAsyncCallVtable())
  result.add describe("logos_provider_invocation_t", LogosProviderInvocation())
  result.add describe("logos_async_provider_api_t", LogosAsyncProviderApi())
  result.add describe("logos_module_init_input_t", LogosModuleInitInput())
  result.add describe("logos_runtime_control_binding_t", LogosRuntimeControlBinding())
  result.add describe("logos_route_handle_t", LogosRouteHandle())
  result.add describe("logos_runtime_control_vtable_t", LogosRuntimeControlVtable())
  result.add describe("logos_route_vtable_t", LogosRouteVtable())
  for (t, n) in [
    ("logos_error_code_t", sizeof(CErrorCode)),
    ("logos_subscription_id_t", sizeof(LogosSubscriptionId)),
  ]:
    result.add (
      "printf(\"" & t & " size %zu\\n\", sizeof(" & t & "));", t & " size " & $n
    )
  for (m, v) in [
    ("LOGOS_MODULE_INIT_ABI_VERSION", ModuleInitAbiVersion),
    ("LOGOS_RUNTIME_CONTROL_VTABLE_ABI_VERSION", RuntimeControlVtableAbiVersion),
    ("LOGOS_ROUTE_VTABLE_ABI_VERSION", RouteVtableAbiVersion),
    ("LOGOS_ASYNC_CALL_ABI_VERSION", AsyncCallAbiVersion),
    ("LOGOS_ASYNC_PROVIDER_ABI_VERSION", AsyncProviderAbiVersion),
    ("LOGOS_INVOCATION_CONTEXT_ABI_VERSION", InvocationContextAbiVersion),
    ("LOGOS_CALLER_MODULE", CallerModule),
    ("LOGOS_CALLER_SYSTEM_SERVICE", CallerSystemService),
    ("LOGOS_ERROR_MESSAGE_MAX_LEN", uint32(MaxMessageBytes)),
    ("LOGOS_ERROR_DETAIL_MAX_LEN", uint32(MaxDetailBytes)),
  ]:
    result.add ("printf(\"" & m & " %u\\n\", (unsigned)" & m & ");", m & " " & $v)

proc cCompiler(): string =
  result = getEnv("CC")
  for name in ["cc", "gcc", "clang"]:
    if result.len == 0:
      result = findExe(name)

proc cLayout(
    facts: seq[(string, string)], header = "logos_types.h"
): Result[seq[string], string] =
  ## What the C compiler says about each fact, from the generated `header`.
  let cc = cCompiler()
  if cc.len == 0:
    return err("no C compiler on PATH")
  createDir(outDir)
  writeFile(outDir / "logos_types.h", logosTypesHeader())
  writeFile(outDir / "logos_runtime.h", logosRuntimeHeader())
  var src =
    "#include <stdio.h>\n#include <stddef.h>\n#include \"" & header & "\"\n" &
    "int main(void) {\n"
  for (stmt, _) in facts:
    src.add "  " & stmt & "\n"
  src.add "  return 0;\n}\n"
  let base = outDir / "layout"
  writeFile(base & ".c", src)
  let exe = base & (when defined(windows): ".exe" else: "")
  let (o, rc) = execCmdEx(
    quoteShell(cc) & " -std=c17 -Wall -Werror -I " & quoteShell(outDir) & " " &
      quoteShell(base & ".c") & " -o " & quoteShell(exe)
  )
  if rc != 0:
    return err(o)
  let (run, rc2) = execCmdEx(quoteShell(exe))
  if rc2 != 0:
    return err(run)
  ok(run.strip.splitLines)

suite "ifc.abi-types: the §5.2 structs in Nim (INTERFACE §5.2)":
  test "[IFC-0934] every struct, field, size, alignment and version constant matches logos_types.h":
    let facts = layoutFacts()
    when deviceTarget:
      skip()
    else:
      let got = cLayout(facts)
      if got.isErr:
        checkpoint got.error
        fail()
      else:
        check got.get.len == facts.len
        for i, (_, want) in facts:
          if i < got.get.len and got.get[i] != want:
            checkpoint "C: " & got.get[i] & "  Nim: " & want
            fail()

  test "each version's minimum struct_size is its last field's end":
    check InitInputV2Extent == sizeof(LogosModuleInitInput)
    check RouteVtableV2Extent == sizeof(LogosRouteVtable)
    check RuntimeControlVtableV2Extent == sizeof(LogosRuntimeControlVtable)
    # A bool before a uint64 leaves padding, but the last field ends the struct.
    check AsyncOptionsV1Extent == sizeof(LogosAsyncOptions)
    check RouteVtableV2Extent - sizeof(pointer) == offsetOf(
      LogosRouteVtable, observeEnd
    )

proc hostLayoutFacts(): seq[(string, string)] =
  result.add describe("logos_runtime_config_t", LogosRuntimeConfig())
  result.add describe("logos_runtime_native_symbol_t", LogosRuntimeNativeSymbol())
  result.add describe("logos_runtime_native_binding_t", LogosRuntimeNativeBinding())
  for (t, n) in [
    ("logos_runtime_symbol_address_t", sizeof(LogosRuntimeSymbolAddress)),
    ("logos_runtime_t*", sizeof(ptr LogosRuntimeHandle)),
  ]:
    result.add (
      "printf(\"" & t & " size %zu\\n\", sizeof(" & t & "));", t & " size " & $n
    )
  const m = "LOGOS_RUNTIME_HOST_ABI_VERSION"
  result.add (
    "printf(\"" & m & " %u\\n\", (unsigned)" & m & ");",
    m & " " & $RuntimeHostAbiVersion,
  )

suite "run.host-abi: the §13.3 structures in Nim (RUNTIME §13, §13.3)":
  test "[RUN-0716] [RUN-0739] every host struct, field, size, alignment and the version constant matches logos_runtime.h":
    let facts = hostLayoutFacts()
    when deviceTarget:
      skip()
    else:
      let got = cLayout(facts, "logos_runtime.h")
      if got.isErr:
        checkpoint got.error
        fail()
      else:
        check got.get.len == facts.len
        for i, (_, want) in facts:
          if i < got.get.len and got.get[i] != want:
            checkpoint "C: " & got.get[i] & "  Nim: " & want
            fail()

  test "each host struct's version-1 minimum struct_size is its last field's end":
    check RuntimeConfigV1Extent ==
      offsetOf(LogosRuntimeConfig, configurationLen) + sizeof(csize_t)
    check NativeBindingV1Extent ==
      offsetOf(LogosRuntimeNativeBinding, symbolCount) + sizeof(csize_t)

# Bindings ----------------------------------------------------------------------------

suite "ifc.abi-bindings: Runtime Control, route and call bindings (INTERFACE §5.2, §2.9.1)":
  test "[IFC-0486] [IFC-0937] [IFC-0938] a valid Runtime Control binding passes; null vtable, state or any operation is MODULE_ERROR, and nothing is called":
    calls = 0
    var vt = rcVtable()
    var b = LogosRuntimeControlBinding(vtable: addr vt, state: somewhere)
    check checkRuntimeControl(addr b).isOk
    check checkRuntimeControl(nil).code == ecModule
    var noVt = LogosRuntimeControlBinding(vtable: nil, state: somewhere)
    check checkRuntimeControl(addr noVt).code == ecModule
    var noState = LogosRuntimeControlBinding(vtable: addr vt, state: nil)
    check checkRuntimeControl(addr noState).code == ecModule
    let names = opNames(vt)
    check names.len == 8
    for k in 0 ..< names.len:
      var w = nulled(vt, k)
      var wb = LogosRuntimeControlBinding(vtable: addr w, state: somewhere)
      let r = checkRuntimeControl(addr wb)
      checkpoint names[k]
      check r.code == ecModule
      check snake(names[k]) in r.error.reason
    check calls == 0

  test "[IFC-0486] [IFC-0936] [IFC-0482] [IFC-0487] an unsupported version or short extent is VERSION_MISMATCH, decided before any operation is read":
    var vt = rcVtable()
    var b = LogosRuntimeControlBinding(vtable: addr vt, state: somewhere)
    for v in [0'u32, 1, 3]:
      vt.abiVersion = v
      check checkRuntimeControl(addr b).code == ecVersionMismatch
    vt.abiVersion = 2
    vt.structSize = csize_t(RuntimeControlVtableV2Extent - 1)
    check checkRuntimeControl(addr b).code == ecVersionMismatch
    # Past the extent every operation is null: still VERSION_MISMATCH, so no
    # field beyond struct_size decided the outcome.
    var short = nulled(nulled(rcVtable(), 7), 6)
    short.structSize = csize_t(offsetOf(LogosRuntimeControlVtable, release))
    var sb = LogosRuntimeControlBinding(vtable: addr short, state: somewhere)
    check checkRuntimeControl(addr sb).code == ecVersionMismatch

  test "[IFC-0483] [IFC-0488] a larger struct_size (fields appended by a later revision) is accepted":
    var vt = rcVtable()
    vt.structSize = csize_t(sizeof(LogosRuntimeControlVtable) + 64)
    var b = LogosRuntimeControlBinding(vtable: addr vt, state: somewhere)
    check checkRuntimeControl(addr b).isOk

  test "[IFC-0935] [IFC-0486] [IFC-0937] a route handle needs observe_end; a version-2 vtable without it is VERSION_MISMATCH":
    calls = 0
    var vt = routeVtable()
    var r = LogosRouteHandle(vtable: addr vt, state: somewhere)
    check checkRoute(addr r).isOk
    vt.structSize = csize_t(offsetOf(LogosRouteVtable, observeEnd))
    check checkRoute(addr r).code == ecVersionMismatch
    vt = routeVtable()
    let names = opNames(vt)
    check names ==
      @[
        "call", "releaseResponse", "subscribe", "unsubscribe", "release", "prepareCall",
        "observeEnd",
      ]
    for k in 0 ..< names.len:
      var w = nulled(vt, k)
      var wr = LogosRouteHandle(vtable: addr w, state: somewhere)
      check checkRoute(addr wr).code == ecModule
    var noState = LogosRouteHandle(vtable: addr vt, state: nil)
    check checkRoute(addr noState).code == ecModule
    check calls == 0

  test "[IFC-0950] [IFC-0951] a prepared call is checked through its vtable":
    var vt = callVtable()
    var c = LogosAsyncCall(vtable: addr vt, state: somewhere)
    check checkAsyncCall(addr c).isOk
    for k in 0 ..< 3:
      var w = nulled(vt, k)
      var wc = LogosAsyncCall(vtable: addr w, state: somewhere)
      check checkAsyncCall(addr wc).code == ecModule
    vt.abiVersion = 2
    check checkAsyncCall(addr c).code == ecVersionMismatch
    vt = callVtable()
    vt.structSize = csize_t(AsyncCallVtableV1Extent - 1)
    check checkAsyncCall(addr c).code == ecVersionMismatch

# Initialization input ---------------------------------------------------------------

suite "ifc.abi-init: the module initialization input (INTERFACE §2.6, §5.2)":
  setup:
    var vt {.inject.} = rcVtable()
    var rc {.inject.} = LogosRuntimeControlBinding(vtable: addr vt, state: somewhere)
    var input {.inject.} = armed(
      LogosModuleInitInput(
        abiVersion: 2,
        structSize: csize_t(sizeof(LogosModuleInitInput)),
        runtimeControl: addr rc,
        invocationAccess: LogosInvocationAccess(state: somewhere),
      )
    )
    input.invocationAccess = armed(input.invocationAccess)

  test "a complete version-2 input passes, with or without events":
    check checkInitInput(addr input, declaresEvents = false).isOk
    check checkInitInput(addr input, declaresEvents = true).isOk

  test "[IFC-0485] an unsupported version or too small an input is VERSION_MISMATCH":
    for v in [1'u32, 3]:
      input.abiVersion = v
      check checkInitInput(addr input, false).code == ecVersionMismatch
    input.abiVersion = 2
    input.structSize = csize_t(offsetOf(LogosModuleInitInput, invocationAccess))
    check checkInitInput(addr input, false).code == ecVersionMismatch
    input.structSize = csize_t(sizeof(LogosModuleInitInput) + 16)
    check checkInitInput(addr input, false).isOk

  test "[IFC-0520] runtime_control is required and checked as a binding":
    input.runtimeControl = nil
    check checkInitInput(addr input, false).code == ecModule
    input.runtimeControl = addr rc
    vt.abiVersion = 1
    check checkInitInput(addr input, false).code == ecVersionMismatch
    vt = nulled(rcVtable(), 0)
    check checkInitInput(addr input, false).code == ecModule

  test "[IFC-0949] invocation_access.state and .current are required":
    input.invocationAccess.state = nil
    check checkInitInput(addr input, false).code == ecModule
    input.invocationAccess.state = somewhere
    input.invocationAccess.current = nil
    check checkInitInput(addr input, false).code == ecModule

  test "[IFC-0523] publish is required when the call surface declares an event":
    input.publish = nil
    check checkInitInput(addr input, declaresEvents = false).isOk
    check checkInitInput(addr input, declaresEvents = true).code == ecModule

  test "[IFC-0519] configuration is absent (null, zero) or one deterministic-CBOR value":
    let good = @[0xA1'u8, 0x61, 0x61, 0x01] # {"a": 1}
    input.configurationCbor = dataOf(good)
    input.configurationCborLen = csize_t(good.len)
    check checkInitInput(addr input, false).isOk
    input.configurationCborLen = 0
    check checkInitInput(addr input, false).code == ecInvalidParams
    input.configurationCbor = nil
    input.configurationCborLen = 4
    check checkInitInput(addr input, false).code == ecInvalidParams
    for bad in [
      @[0xA1'u8, 0x61, 0x61, 0x01, 0x00], # trailing byte: two values
      @[0x18'u8, 0x01], # 1 in a non-shortest form
      @[0xA1'u8, 0x61], # truncated
    ]:
      input.configurationCbor = dataOf(bad)
      input.configurationCborLen = csize_t(bad.len)
      check checkInitInput(addr input, false).code == ecInvalidParams
    check checkConfigurationBytes(nil, 0, required = true).code == ecInvalidParams
    check checkConfigurationBytes(dataOf(good), csize_t(good.len), required = true).isOk
    # [SPEC CONFIG §6 l.226] What a Runtime delivers: one configuration_input
    # (DECISIONS I87).
    let value = newBlob(good)
    let delivered = encodeInput(
      ValueRecord(
        value: value,
        commitment: SchemaRoots(),
        valueRevision: 1,
        provenance: pvPackageDefault,
      )
    )
    drop(value)
    input.configurationCbor = dataOf(delivered)
    input.configurationCborLen = csize_t(delivered.len)
    check checkInitInput(addr input, false).isOk

  test "state_dir, when present, is UTF-8":
    input.stateDir = "/var/lib/logos/ëx"
    check checkInitInput(addr input, false).isOk
    var bad = "/tmp/\xff"
    input.stateDir = cstring(bad)
    check checkInitInput(addr input, false).code == ecInvalidParams

# Results and outputs -----------------------------------------------------------------

proc res(code: int, msg: cstring = nil, detail: seq[byte] = @[]): LogosResult =
  result.code = CErrorCode(code)
  result.message = msg
  if detail.len > 0:
    result.detail = dataOf(detail)
    result.detailLen = csize_t(detail.len)

let filled = OutputShape(success: true, failure: false)
let untouched = OutputShape(success: false, failure: true)
let mixed = OutputShape(success: false, failure: false)

suite "ifc.abi-outcomes: result and output combinations (INTERFACE §2.4, §2.6, §5.2)":
  test "[IFC-0223] [IFC-0251] [IFC-0490] success is LOGOS_OK with the outputs; failure a nonzero code without them":
    check checkOutcome(res(0), filled).isOk
    let f = checkOutcome(res(4, "denied"), untouched)
    check f.code == ecNotAuthorised
    check f.error.message == Opt.some("denied")
    check f.error.reason == ""

  test "[IFC-0223] [IFC-0251] [IFC-0163] [IFC-0490] every other combination is MODULE_ERROR without diagnostics":
    for (r, o) in [
      (res(0), untouched), (res(0), mixed), (res(3), filled), (res(2, "x"), mixed)
    ]:
      let c = checkOutcome(r, o)
      check c.code == ecModule
      check c.error.message.isNone and c.error.detail.isNone
      check c.error.reason.len > 0

  test "[IFC-0476] the message is NULL on LOGOS_OK and at most 512 UTF-8 bytes":
    check checkOutcome(res(0, "fine"), filled).code == ecModule
    let at = 'm'.repeat(512)
    check checkOutcome(res(6, cstring(at)), untouched).error.message == Opt.some(at)
    let over = 'm'.repeat(513)
    let o = checkOutcome(res(6, cstring(over)), untouched)
    check o.code == ecModule and o.error.message.isNone
    var notUtf8 = "\xc3("
    check checkOutcome(res(6, cstring(notUtf8)), untouched).code == ecModule

  test "detail: null and zero, or 1 to 4096 bytes of a valid INVALID_PARAMS detail":
    let d = invalidParamsDetail(iprSchemaMismatch)
    let ok = checkOutcome(res(2, nil, d), untouched)
    check ok.code == ecInvalidParams and ok.error.detail == Opt.some(d)
    check checkOutcome(res(6, nil, d), untouched).code == ecModule
    var r = res(2)
    r.detailLen = 3
    check checkOutcome(r, untouched).code == ecModule
    r = res(2, nil, d)
    r.detailLen = 0
    check checkOutcome(r, untouched).code == ecModule
    r.detailLen = csize_t(MaxDetailBytes + 1)
    check checkOutcome(r, untouched).code == ecModule

  test "an unallocated code is MODULE_ERROR":
    for c in [10, 42, -1]:
      check checkOutcome(res(c), untouched).code == ecModule

  test "output shapes for buffers, handles and contexts":
    let one = @[0xA0'u8]
    check bufferShape(nil, 0) == untouched
    check bufferShape(unsafeAddr one[0], 1) == filled
    check bufferShape(unsafeAddr one[0], 0) == mixed
    check bufferShape(nil, 1) == mixed
    check handleShape(nil, nil) == untouched
    check handleShape(somewhere, somewhere) == filled
    check handleShape(somewhere, nil) == mixed
    check handleShape(nil, somewhere) == mixed
    check contextShape(nil) == untouched
    check contextShape(cast[ptr LogosModuleContext](somewhere)) == filled

  test "[IFC-0684] an owner is empty, or has a release function":
    check ownerEmpty(LogosResponseOwner())
    check ownerValid(LogosResponseOwner())
    let rel = cast[ReleaseFn](stubAddr)
    check ownerValid(LogosResponseOwner(state: nil, release: rel))
    check ownerValid(LogosResponseOwner(state: somewhere, release: rel))
    check not ownerValid(LogosResponseOwner(state: somewhere, release: nil))

  test "[IFC-0163] [IFC-0651] typed calls: success needs a valid owner; failure leaves owner and outputs at zero, and no release is called":
    calls = 0
    let rel = cast[ReleaseFn](stubAddr)
    let owned = LogosResponseOwner(state: somewhere, release: rel)
    check checkOutcome(res(0), typedShape(owned, untouched = false, complete = true)).isOk
    # A response of zeros with an empty owner (a uint64 0) is a success.
    check checkOutcome(res(0), typedShape(LogosResponseOwner(), true, true)).isOk
    check checkOutcome(
      res(0), typedShape(LogosResponseOwner(state: somewhere), false, true)
    ).code == ecModule
    check checkOutcome(res(0), typedShape(owned, false, complete = false)).code ==
      ecModule
    check checkOutcome(res(3), typedShape(LogosResponseOwner(), true, false)).code ==
      ecModule
    check checkOutcome(res(3), typedShape(LogosResponseOwner(), true, false)).error.reason ==
      ""
    check checkOutcome(res(3), typedShape(owned, true, false)).error.reason.len > 0
    check checkOutcome(res(3), typedShape(LogosResponseOwner(), false, false)).error.reason.len >
      0
    check calls == 0

  test "completions: an owner may accompany a failure; an invalid owner is MODULE_ERROR":
    let one = @[0xA0'u8]
    let rel = cast[ReleaseFn](stubAddr)
    let owned = LogosResponseOwner(state: somewhere, release: rel)
    check checkOutcome(res(0), completionShape(dataOf(one), 1, LogosResponseOwner())).isOk
    check checkOutcome(res(0), completionShape(dataOf(one), 1, owned)).isOk
    check checkOutcome(res(5, "lost"), completionShape(nil, 0, owned)).code ==
      ecTransport
    let bad = LogosResponseOwner(state: somewhere)
    check checkOutcome(res(0), completionShape(dataOf(one), 1, bad)).error.reason.len > 0
    check checkOutcome(res(5), completionShape(nil, 0, bad)).error.reason.len > 0

# Asynchronous calls, provider completion and context ---------------------------------

suite "ifc.abi-async: options, callbacks, provider descriptor, invocation and context (INTERFACE §2.9, §5.2)":
  test "[IFC-0950] options: version 1 and its extent, else VERSION_MISMATCH; null is INVALID_PARAMS":
    var o =
      LogosAsyncOptions(abiVersion: 1, structSize: csize_t(sizeof(LogosAsyncOptions)))
    check checkAsyncOptions(addr o).isOk
    o.abiVersion = 2
    check checkAsyncOptions(addr o).code == ecVersionMismatch
    o.abiVersion = 1
    o.structSize = csize_t(offsetOf(LogosAsyncOptions, timeoutMs))
    check checkAsyncOptions(addr o).code == ecVersionMismatch
    check checkAsyncOptions(nil).code == ecInvalidParams

  test "[IFC-0950] [IFC-0951] callbacks: version and extent are VERSION_MISMATCH; a null complete is INVALID_PARAMS":
    var c = armed(
      LogosAsyncCallbacks(
        abiVersion: 1, structSize: csize_t(sizeof(LogosAsyncCallbacks))
      )
    )
    check checkAsyncCallbacks(addr c).isOk
    c.structSize = csize_t(offsetOf(LogosAsyncCallbacks, userData))
    check checkAsyncCallbacks(addr c).code == ecVersionMismatch
    c.structSize = csize_t(sizeof(LogosAsyncCallbacks))
    c.complete = nil
    check checkAsyncCallbacks(addr c).code == ecInvalidParams
    check checkAsyncCallbacks(nil).code == ecInvalidParams

  test "[IFC-0744] [IFC-0745] [IFC-0951] the provider descriptor: absent, or version 1 with submit; request_cancel optional":
    calls = 0
    check checkAsyncProviderApi(nil).isOk
    var api = armed(
      LogosAsyncProviderApi(
        abiVersion: 1, structSize: csize_t(sizeof(LogosAsyncProviderApi))
      )
    )
    check checkAsyncProviderApi(addr api).isOk
    api.requestCancel = nil
    check checkAsyncProviderApi(addr api).isOk
    api.submit = nil
    check checkAsyncProviderApi(addr api).code == ecModule
    api = armed(api)
    api.abiVersion = 2
    check checkAsyncProviderApi(addr api).code == ecVersionMismatch
    api.abiVersion = 1
    api.structSize = csize_t(offsetOf(LogosAsyncProviderApi, requestCancel))
    check checkAsyncProviderApi(addr api).code == ecVersionMismatch
    check calls == 0

  test "[IFC-0950] [IFC-0951] the invocation context: vtable, state, version 1 and three operations":
    var vt = ctxVtable()
    var c = LogosInvocationContext(vtable: addr vt, state: somewhere)
    check checkInvocationContext(addr c).isOk
    check checkInvocationContext(nil).code == ecModule
    for k in 0 ..< 3:
      var w = nulled(vt, k)
      var wc = LogosInvocationContext(vtable: addr w, state: somewhere)
      check checkInvocationContext(addr wc).code == ecModule
    var noState = LogosInvocationContext(vtable: addr vt, state: nil)
    check checkInvocationContext(addr noState).code == ecModule
    vt.structSize = csize_t(offsetOf(LogosInvocationContextVtable, publish))
    check checkInvocationContext(addr c).code == ecVersionMismatch

  test "[IFC-0950] [IFC-0951] a provider invocation: version 1, method, request, context and both operations":
    var vt = ctxVtable()
    var ctx = LogosInvocationContext(vtable: addr vt, state: somewhere)
    let req = @[0xA0'u8]
    let base = armed(
      LogosProviderInvocation(
        abiVersion: 1,
        structSize: csize_t(sizeof(LogosProviderInvocation)),
        `method`: "get",
        paramsCbor: dataOf(req),
        paramsCborLen: 1,
        context: addr ctx,
      )
    )
    var inv = base
    check checkProviderInvocation(addr inv).isOk
    check checkProviderInvocation(nil).code == ecModule
    for k in 0 ..< 2:
      inv = nulled(base, k)
      check checkProviderInvocation(addr inv).code == ecModule
    inv = base
    inv.`method` = nil
    check checkProviderInvocation(addr inv).code == ecModule
    inv = base
    inv.paramsCborLen = 0
    check checkProviderInvocation(addr inv).code == ecModule
    inv = base
    inv.context = nil
    check checkProviderInvocation(addr inv).code == ecModule
    inv = base
    inv.structSize = csize_t(offsetOf(LogosProviderInvocation, executionRelease))
    check checkProviderInvocation(addr inv).code == ecVersionMismatch
    inv = base
    vt.abiVersion = 2
    check checkProviderInvocation(addr inv).code == ecVersionMismatch

  test "caller views: a module caller has both identifiers; a system service only the Runtime's":
    let rt = bytesOf("rt-1")
    let mi = bytesOf("mod-7")
    let rtv = LogosUtf8View(data: dataOf(rt), len: csize_t(rt.len))
    let miv = LogosUtf8View(data: dataOf(mi), len: csize_t(mi.len))
    check checkCallerView(
      LogosCallerView(kind: CallerModule, runtimeInstanceId: rtv, moduleInstanceId: miv)
    ).isOk
    check checkCallerView(LogosCallerView(kind: CallerModule, runtimeInstanceId: rtv)).code ==
      ecModule
    check checkCallerView(
      LogosCallerView(kind: CallerSystemService, runtimeInstanceId: rtv)
    ).isOk
    check checkCallerView(
      LogosCallerView(
        kind: CallerSystemService, runtimeInstanceId: rtv, moduleInstanceId: miv
      )
    ).code == ecModule
    check checkCallerView(LogosCallerView(kind: 3, runtimeInstanceId: rtv)).code ==
      ecModule
    let bad = @[0xFF'u8]
    check checkCallerView(
      LogosCallerView(
        kind: CallerSystemService,
        runtimeInstanceId: LogosUtf8View(data: dataOf(bad), len: 1),
      )
    ).code == ecModule
    check checkCallerView(
      LogosCallerView(
        kind: CallerSystemService, runtimeInstanceId: LogosUtf8View(data: nil, len: 2)
      )
    ).code == ecModule

# Runtime-side input shapes -----------------------------------------------------------

suite "ifc.abi-inputs: materialize_route and connect_remote input shapes (INTERFACE §5.2)":
  test "[IFC-0511] materialize_route needs a route id, a root and 1 to 8,388,608 schema bytes":
    var root: ContractRoot
    let one = @[0xA0'u8]
    check checkMaterializeInput("r1", addr root, dataOf(one), 1).isOk
    check checkMaterializeInput(nil, addr root, dataOf(one), 1).code == ecInvalidParams
    check checkMaterializeInput("r1", nil, dataOf(one), 1).code == ecInvalidParams
    check checkMaterializeInput("r1", addr root, nil, 1).code == ecInvalidParams
    check checkMaterializeInput("r1", addr root, dataOf(one), 0).code == ecInvalidParams
    check checkMaterializeInput("r1", addr root, dataOf(one), 8_388_608).isOk
    check checkMaterializeInput("r1", addr root, dataOf(one), 8_388_609).code ==
      ecInvalidParams

  test "connect_remote needs endpoint bytes and a root":
    var root: ContractRoot
    let one = @[0xA0'u8]
    check checkConnectRemoteInput(dataOf(one), 1, addr root).isOk
    check checkConnectRemoteInput(nil, 0, addr root).code == ecInvalidParams
    check checkConnectRemoteInput(dataOf(one), 1, nil).code == ecInvalidParams
