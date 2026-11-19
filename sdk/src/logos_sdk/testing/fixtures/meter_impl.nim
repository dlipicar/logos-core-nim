## A native module written with the lcn-gen kit for `meter_module` (INTERFACE
## §3.9.1): what a module author writes. `sdk/tests/test_kit.nim` links it and calls
## its exported C symbols; on a host it is also built as a shared library.
##
## Channels select behaviour: 13 fails with a message, 14 returns a response
## outside its schema, 15 publishes `meter.changed_event`, 16 returns a failure
## that is not a valid status, 17 reads the caller and publishes in the
## invocation's scope, 18 reads the caller and whether the invocation is
## cancelled, 19 does what 18 does once `gate` opens, 20 reads this
## instance's own state (the last part of its state directory, or `none`, and
## its count of reads), 21 publishes `meter.changed_event` and then reads the
## caller, 22 adds a line to the file `held` in its state directory and does
## what 18 does once the invocation is cancelled or the file `open` is there
## (for a module in a Module Host, where the test cannot reach `gate`; at most
## ten minutes of wall time), 23 does what 22 does but waits for `open` alone,
## and writes the file `cancelled` there once it sees the invocation
## cancelled, 24 publishes `meter.changed_event` with value 0x6C636E32 and then
## in the invocation's scope with value 0x6C636E33 (payloads a carrier trace
## looks for), 25 publishes `meter.changed_event` with value 250 from a thread
## of the module's own runtime, then joins it (DECISIONS G342: a module thread
## calling the host's publish callback), 26 publishes `meter.unknown_event`,
## `meter.changed_event` with a text value and then with value 260, and reads
## `ch26` with a value whose bits 0, 1 and 2 say that the callback refused the
## first two with INVALID_PARAMS and took the third (INTERFACE l.3351);
## any other channel `c` reads `ch<c>` with value `10 c`.

{.used.} # imported by the tests for the C symbols it exports
import std/[atomics, monotimes, os, times]
import ../generated/meter_module_kit

type Meter* = ref object
  services*: ModuleServices
  stateDir*: Opt[string]
  configuration*: Opt[seq[byte]]
  reads*: Atomic[int]

var
  destroyed*: Atomic[int] ## instances `destroyModule` has seen
  gate*: Atomic[bool] ## channel 19 waits while it is true
  held*: Atomic[int] ## calls waiting at `gate`

proc initModule(_: type Meter, init: ModuleInit): Result[Meter, InvocationFailure] =
  if init.stateDir == Opt.some("/refuse"): # refuse to start
    return err(failure(ecModule, "the state directory says no"))
  ok(
    Meter(
      services: init.services,
      stateDir: init.stateDir,
      configuration: init.configuration,
    )
  )

proc destroyModule(m: Meter) =
  destroyed += 1

var threadPublished*: Atomic[int] ## channel 25's publications the callback took

proc publisher(s: ModuleServices) {.thread.} =
  if s.publish(MeterChangedEvent(value: 250)).isOk:
    threadPublished += 1

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
  of 18, 19, 22, 23:
    if c == 19:
      held += 1
      while gate.load:
        sleep(1)
      held -= 1
    if c == 22 or c == 23:
      let dir = m.stateDir.get("/nonexistent")
      try:
        let f = open(dir / "held", fmAppend)
        f.write("held\n")
        f.close()
      except CatchableError:
        discard
      let opened = dir / "open"
      # [IMPL] Wall time, past every hold a test asks for: counted in 1 ms
      # sleeps, a minute was reached before test_hosted_routes C-8's timeout
      # under TSan on a host at load 100 (4b-8's closing check).
      let until = getMonoTime() + initDuration(minutes = 10)
      var told = false
      while (c == 23 or not m.services.isCancelled) and not fileExists(opened) and
          getMonoTime() < until:
        if c == 23 and not told and m.services.isCancelled:
          told = true
          try:
            writeFile(dir / "cancelled", "")
          except CatchableError:
            discard
        sleep(1)
    let who = ?m.services.caller()
    ok(
      MeterReadResponse(
        label: who.moduleInstance.get("system"),
        reading: MeterReading(
          label: Opt.some(who.runtimeInstance),
          value: (if m.services.isCancelled: 1'u64 else: 0'u64),
        ),
      )
    )
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
  of 20:
    ok(
      MeterReadResponse(
        label: lastPathPart(m.stateDir.get("none")),
        reading: MeterReading(value: uint64(m.reads.load)),
      )
    )
  of 24:
    ?m.services.publish(MeterChangedEvent(value: 0x6C636E32'u64))
    ?m.services.publishScoped(MeterChangedEvent(value: 0x6C636E33'u64))
    ok(MeterReadResponse(label: "ch24", reading: MeterReading(value: 240)))
  of 25:
    var t: Thread[ModuleServices]
    try:
      createThread(t, publisher, m.services)
    except CatchableError as e:
      return err(moduleError("channel 25 has no thread: " & e.msg))
    joinThread(t)
    ok(MeterReadResponse(label: "ch25", reading: MeterReading(value: 250)))
  of 26:
    # {}; {"value": "x"}; {"value": 260}
    let
      unknown = m.services.publishEncoded("meter.unknown_event", [0xA0'u8])
      text = m.services.publishEncoded(
        "meter.changed_event", [0xA1'u8, 0x65, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x61, 0x78]
      )
      valid = m.services.publish(MeterChangedEvent(value: 260))
    var bits = 0'u64
    if unknown.isErr and unknown.error.code == ecInvalidParams:
      bits = bits or 1
    if text.isErr and text.error.code == ecInvalidParams:
      bits = bits or 2
    if valid.isOk:
      bits = bits or 4
    ok(MeterReadResponse(label: "ch26", reading: MeterReading(value: bits)))
  of 21:
    ?m.services.publish(MeterChangedEvent(value: 210))
    let who = ?m.services.caller() # after the handlers' nested entries returned
    ok(
      MeterReadResponse(
        label: who.moduleInstance.get("system"), reading: MeterReading(value: 21)
      )
    )
  else:
    ok(
      MeterReadResponse(label: "ch" & $c, reading: MeterReading(value: uint64(c) * 10))
    )

exportMeterModule(Meter)
