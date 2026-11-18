## CONFIG §6 and INTERFACE §5.2: what a Runtime delivers as a module's configuration passes the
## module initialization check. Apart from tests/test_abi.nim because the delivered form is core's.

import unittest2
import logos_sdk/abi/checks
from ../src/logos_core/runtime/config import
  ValueRecord, SchemaRoots, Provenance, newBlob, drop, encodeInput

proc stub() {.cdecl.} =
  discard

let stubAddr = cast[pointer](stub)
  ## Cast through a runtime pointer: a direct proc-to-proc cast reaches the C
  ## compiler as an incompatible function-pointer assignment.

proc procOnly[P: proc](p: P) =
  ## Matches only procedure types: `when compiles(procOnly(f))` selects a
  ## struct's operation fields.
  discard

proc armed[T](v: T): T =
  ## `v` with every operation set to the stub.
  result = v
  for f in fields(result):
    when compiles(procOnly(f)):
      f = cast[typeof(f)](stubAddr)

var stateByte: byte
let somewhere = cast[pointer](addr stateByte)

proc rcVtable(): LogosRuntimeControlVtable =
  armed(
    LogosRuntimeControlVtable(
      abiVersion: 2, structSize: csize_t(sizeof(LogosRuntimeControlVtable))
    )
  )

template dataOf(b: seq[byte]): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](unsafeAddr b[0])

suite "cfg.abi-init: the configuration a Runtime delivers (CONFIG §6, INTERFACE §5.2)":
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

  test "one delivered configuration_input is one deterministic-CBOR value":
    # [SPEC CONFIG §6 l.226] What a Runtime delivers: one configuration_input
    # (DECISIONS I87).
    let good = @[0xA1'u8, 0x61, 0x61, 0x01] # {"a": 1}
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
