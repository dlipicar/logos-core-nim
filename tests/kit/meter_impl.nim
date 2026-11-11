## A native module written with the lcn-gen kit for `meter_module` (INTERFACE
## §3.9.1): what a module author writes. `tests/test_kit.nim` links it and calls
## its exported C symbols; on a host it is also built as a shared library.
##
## Channels select behaviour: 13 fails with a message, 14 returns a response
## outside its schema, 15 publishes `meter.changed_event`, 16 returns a failure
## that is not a valid status, 17 reads the caller and publishes in the
## invocation's scope; any other channel `c` reads `ch<c>` with value `10 c`.

{.used.} # imported by the tests for the C symbols it exports
import std/atomics
import ../generated/meter_module_kit

type Meter* = ref object
  services*: ModuleServices
  stateDir*: Opt[string]
  configuration*: Opt[seq[byte]]
  reads*: Atomic[int]

var destroyed*: Atomic[int] ## instances `destroyModule` has seen

proc initModule(_: type Meter, init: ModuleInit): Result[Meter, InvocationFailure] =
  if init.configuration == Opt.some(@[0xF4'u8]): # CBOR `false`: refuse to start
    return err(failure(ecModule, "configuration says no"))
  ok(
    Meter(
      services: init.services,
      stateDir: init.stateDir,
      configuration: init.configuration,
    )
  )

proc destroyModule(m: Meter) =
  destroyed += 1

proc `read`(
    m: Meter, request: MeterReadRequest
): Result[MeterReadResponse, InvocationFailure] =
  m.reads += 1
  let c = request.channel
  case c
  of 13:
    err(failure(ecModule, "channel 13 is broken"))
  of 14:
    ok(MeterReadResponse(label: "", reading: MeterReading(value: 0))) # label: 1..64
  of 15:
    ?m.services.publish(MeterChangedEvent(value: 150))
    ok(MeterReadResponse(label: "published", reading: MeterReading(value: 15)))
  of 16:
    err(InvocationFailure(code: ecOk))
  of 17:
    let who = ?m.services.caller()
    ?m.services.publishScoped(MeterChangedEvent(value: 170))
    ok(
      MeterReadResponse(
        label: who.moduleInstance.get("system"),
        reading: MeterReading(
          label: Opt.some(who.runtimeInstance),
          value: (if m.services.isCancelled: 1'u64 else: 0'u64),
        ),
      )
    )
  else:
    ok(
      MeterReadResponse(label: "ch" & $c, reading: MeterReading(value: uint64(c) * 10))
    )

exportMeterModule(Meter)
