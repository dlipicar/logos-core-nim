## Asynchronous calls (`runtime/asynccall.nim`, `runtime/engine.nim`): calls
## prepared through a route handle (INTERFACE §2.9.1) or Runtime Control
## (§2.9; RUNTIME §7.5), and deferred provider completion (INTERFACE §2.9.2,
## §2.9.3).
##
## The provider is the meter kit module (channel 19 waits while `gate` is
## closed and reports whether its invocation is cancelled), or its deferred
## variant (`kit/deferred_adapter`), which parks invocations for the test to
## complete from its own thread. Completion callbacks record into `Done`
## slots, which are atomics: they run on the engine's workers.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime]
import ./kit/[deferred_adapter, meter_impl]
import ./generated/[meter_module_calls, meter_module_types]

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "async" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

let dmeterStatic = checkStaticRegistration("dmeter", deferredMeterSymbols()).tryGet

proc dmeter(): ModuleRecord =
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "dmeter",
    primaryContract: Opt.some(meterRoot),
  )

proc req(channel: int): seq[byte] =
  encodeCbor(parseDiag("{\"channel\": " & $channel & "}").get)

# Completion callbacks -----------------------------------------------------------------------

const MaxResponse = 256

type Done = object
  count: Atomic[int] ## callbacks that returned
  inside: Atomic[int]
  code: Atomic[int]
  thread: Atomic[int]
  hold: Atomic[bool] ## the callback waits while it is true
  keep: bool ## keep the response owner for the test
  owner: LogosResponseOwner
  response: ptr UncheckedArray[uint8]
  len: Atomic[int]
  bytes: array[MaxResponse, byte]
  message: array[160, char]

proc clear(d: var Done, keep = false) =
  d.count.store(0)
  d.inside.store(0)
  d.code.store(-1)
  d.thread.store(0)
  d.hold.store(false)
  d.keep = keep
  d.owner = LogosResponseOwner()
  d.response = nil
  d.len.store(0)
  d.message[0] = '\0'

proc onComplete(
    userData: pointer,
    r: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr Done](userData)
  d.inside += 1
  while d.hold.load:
    sleep(1)
  d.thread.store(getThreadId())
  let n = min(int(len), MaxResponse)
  for i in 0 ..< n:
    d.bytes[i] = response[i]
  d.len.store(n)
  d.message[0] = '\0'
  if r.message != nil:
    let m = $r.message
    let k = min(m.len, d.message.len - 1)
    for i in 0 ..< k:
      d.message[i] = m[i]
    d.message[k] = '\0'
  if d.keep:
    d.owner = owner
    d.response = response
  elif not owner.release.isNil:
    owner.release(owner.state)
  d.code.store(int(r.code))
  d.inside -= 1
  d.count += 1

var done: array[4, Done]

proc codeOf(d: var Done): ErrorCode =
  errorCode(int64(d.code.load)).get

proc responseOf(d: var Done): seq[byte] =
  d.bytes[0 ..< d.len.load]

proc messageOf(d: var Done): string =
  $cast[cstring](addr d.message[0])

proc finished(d: var Done, n = 1, seconds = 10 * Slow): bool =
  let p = addr d
  waitUntil(
    proc(): bool =
      p.count.load >= n,
    seconds,
  )

proc options(timeoutMs = -1): LogosAsyncOptions =
  LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncOptions)),
    hasTimeout: timeoutMs >= 0,
    timeoutMs: uint64(max(timeoutMs, 0)),
  )

proc callbacks(d: ptr Done): LogosAsyncCallbacks =
  LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onComplete,
    userData: d,
  )

proc prepare(
    h: var LogosRouteHandle,
    params: openArray[byte],
    d: ptr Done,
    timeoutMs = -1,
    name = "read",
): (ErrorCode, LogosAsyncCall) =
  var o = options(timeoutMs)
  var cb = callbacks(d)
  var c = LogosAsyncCall()
  let r = h.vtable.prepareCall(
    addr h,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr o,
    addr cb,
    addr c,
  )
  (toResult(r).code, c)

proc rcPrepare(
    rc: ptr LogosRuntimeControlBinding,
    name: string,
    params: openArray[byte],
    d: ptr Done,
    timeoutMs = -1,
): (ErrorCode, LogosAsyncCall) =
  var o = options(timeoutMs)
  var cb = callbacks(d)
  var c = LogosAsyncCall()
  let r = rc.vtable.prepareCall(
    rc,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr o,
    addr cb,
    addr c,
  )
  (toResult(r).code, c)

proc submit(c: var LogosAsyncCall) =
  c.vtable.submit(addr c)

proc cancel(c: var LogosAsyncCall) =
  c.vtable.cancel(addr c)

proc release(c: var LogosAsyncCall) =
  c.vtable.release(addr c)

proc started(
    h: var LogosRouteHandle, params: openArray[byte], d: ptr Done, timeoutMs = -1
): LogosAsyncCall =
  let (code, c) = h.prepare(params, d, timeoutMs)
  check code == ecOk
  result = c
  result.submit()

type Job = object
  call: ptr LogosAsyncCall
  done: Atomic[bool]

proc releases(j: ptr Job) {.thread.} =
  j.call.vtable.release(j.call)
  j.done.store(true)

# Event handlers for scoped publication -------------------------------------------------------

var heard: array[2, Atomic[int]]

proc onEvent(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  cast[ptr Atomic[int]](userData)[] += 1

proc listen(h: var LogosRouteHandle, slot: int): LogosSubscriptionId =
  check toResult(
    h.vtable.subscribe(
      addr h, "meter.changed_event", onEvent, addr heard[slot], addr result
    )
  ).code == ecOk

# Tests ------------------------------------------------------------------------------------

suite "run.async: route calls (INTERFACE §2.9.1)":
  setup:
    for d in done.mitems:
      d.clear()
    gate.store(false)
  teardown:
    for d in done.mitems:
      d.hold.store(false) # a held callback would keep `close` waiting
    leftover()

  test "[IFC-0712] [IFC-0713] [IFC-0714] a call over the synchronous provider ABI completes on another thread; submit returns before the provider runs":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (c, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let expected = h.raw("read", req(5)).response
    var call = h.started(req(5), addr done[0])
    check done[0].finished
    check done[0].codeOf == ecOk
    check done[0].responseOf == expected
    check done[0].thread.load != getThreadId()
    call.release()
    gate.store(true)
    let before = held.load
    var slow = h.started(req(19), addr done[1])
    check done[1].count.load == 0
    check waitUntil(
      proc(): bool =
        held.load == before + 1
    )
    check done[1].count.load == 0
    gate.store(false)
    check done[1].finished
    check done[1].codeOf == ecOk
    let r = MeterReadResponse.decode(done[1].responseOf).tryGet
    check r.label == c.instance
    check r.reading.value == 0 # not cancelled
    slow.release()
    h.release()
    e.finish()

  test "[IFC-0717] [IFC-0718] [IFC-0719] preparation copies its inputs and runs nothing; bad options or callbacks leave the outputs null":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    var params = req(5)
    let expected = h.raw("read", req(5)).response
    var (code, call) = h.prepare(params, addr done[0])
    check code == ecOk
    params = req(6)
    for i in 0 ..< params.len:
      params[i] = 0
    sleep(50)
    check done[0].count.load == 0
    call.submit()
    check done[0].finished
    check done[0].responseOf == expected
    call.release()
    # Malformed preparation input.
    var cb = callbacks(addr done[1])
    var o = options()
    var dest = LogosAsyncCall(vtable: nil, state: nil)
    let p = req(5)
    template attempt(opts, cbs: untyped): ErrorCode =
      toResult(
        h.vtable.prepareCall(
          addr h,
          "read",
          cast[ptr UncheckedArray[uint8]](unsafeAddr p[0]),
          csize_t(p.len),
          opts,
          cbs,
          addr dest,
        )
      ).code

    check attempt(nil, addr cb) == ecInvalidParams
    check attempt(addr o, nil) == ecInvalidParams
    var badVersion = options()
    badVersion.abiVersion = 99
    check attempt(addr badVersion, addr cb) == ecVersionMismatch
    var shortCb = callbacks(addr done[1])
    shortCb.structSize = 4
    check attempt(addr o, addr shortCb) == ecVersionMismatch
    var noComplete = callbacks(addr done[1])
    noComplete.complete = nil
    check attempt(addr o, addr noComplete) == ecInvalidParams
    check dest.vtable == nil and dest.state == nil
    check done[1].count.load == 0
    h.release()
    e.finish()

  test "[IFC-0724] [IFC-0726] [IFC-0728] exactly one completion when a result, a cancellation and a timeout race":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    var outcomes: seq[ErrorCode]
    for i in 0 ..< 200:
      done[0].clear()
      var call = h.started(req(i mod 10), addr done[0], timeoutMs = i mod 3)
      if i mod 2 == 0:
        call.cancel()
      call.release()
      check done[0].count.load == 1
      if done[0].codeOf notin outcomes:
        outcomes.add(done[0].codeOf)
    check outcomes.allIt(it in [ecOk, ecCancelled, ecTimeout])
    check ecCancelled in outcomes
    sleep(50)
    check done[0].count.load == 1
    h.release()
    e.finish()

  test "[IFC-0726] a zero timeout expires without dispatch; a held provider times out and its late result is discarded":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    gate.store(true)
    let before = held.load
    var zero = h.started(req(19), addr done[0], timeoutMs = 0)
    check done[0].finished
    check done[0].codeOf == ecTimeout
    sleep(30)
    check held.load == before
    zero.release()
    var late = h.started(req(19), addr done[1], timeoutMs = 300 * Slow)
    check waitUntil(
      proc(): bool =
        held.load == before + 1
    )
    check done[1].finished
    check done[1].codeOf == ecTimeout
    gate.store(false)
    check waitUntil(
      proc(): bool =
        held.load == before
    )
    sleep(30)
    check done[1].count.load == 1
    check done[1].codeOf == ecTimeout
    late.release()
    h.release()
    e.finish()

  test "[IFC-0731] [IFC-0733] [IFC-0735] cancel before submit, cancel after completion, release unsubmitted; release waits for the callback, not the provider":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    # Cancelled before submission: CANCELLED at submit, nothing dispatched.
    gate.store(true)
    let before = held.load
    var (code, early) = h.prepare(req(19), addr done[0])
    check code == ecOk
    early.cancel()
    early.submit()
    check done[0].finished
    check done[0].codeOf == ecCancelled
    check held.load == before
    early.release()
    gate.store(false)
    # Cancelled after its result: nothing changes.
    var quick = h.started(req(5), addr done[1])
    check done[1].finished
    quick.cancel()
    sleep(20)
    check done[1].count.load == 1
    check done[1].codeOf == ecOk
    quick.release()
    # Released before submission: no callback.
    var (code2, idle) = h.prepare(req(5), addr done[2])
    check code2 == ecOk
    idle.release()
    sleep(20)
    check done[2].count.load == 0
    # Release cancels a running call, waits for its callback, not the provider.
    gate.store(true)
    done[3].hold.store(true)
    var running = h.started(req(19), addr done[3])
    check waitUntil(
      proc(): bool =
        held.load == before + 1
    )
    var job = Job(call: addr running)
    var t: Thread[ptr Job]
    createThread(t, releases, addr job)
    check waitUntil(
      proc(): bool =
        done[3].inside.load == 1
    )
    sleep(50)
    check not job.done.load
    done[3].hold.store(false)
    joinThread(t)
    check done[3].count.load == 1
    check done[3].codeOf == ecCancelled
    check held.load == before + 1 # the provider is still inside
    gate.store(false)
    check waitUntil(
      proc(): bool =
        held.load == before
    )
    h.release()
    e.finish()

  test "[IFC-0736] [IFC-0737] the response owner outlives the call and the handle; releasing it frees the copy":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let expected = h.raw("read", req(7)).response
    done[0].clear(keep = true)
    var call = h.started(req(7), addr done[0])
    check done[0].finished
    call.release()
    h.release()
    let n = done[0].len.load
    check n == expected.len
    var kept = newSeq[byte](n)
    for i in 0 ..< n:
      kept[i] = done[0].response[i]
    check kept == expected
    check not done[0].owner.release.isNil
    done[0].owner.release(done[0].owner.state)
    e.finish()

  test "[IFC-0720] [RUN-0807] [RUN-0808] [RUN-0809] the call outlives its handle; an ended route gives its code without dispatch; a restarted provider is never substituted":
    let e = fixtureEngine(config())
    let m = e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var (code, call) = h.prepare(req(5), addr done[0])
    check code == ecOk
    var (code2, after) = h.prepare(req(5), addr done[1])
    check code2 == ecOk
    h.release()
    call.submit()
    check done[0].finished
    check done[0].codeOf == ecOk
    call.release()
    check e.stop(m.instance).tryGet.state == msUnloaded
    check e.start(m.instance).tryGet.state == msReady
    gate.store(true)
    let before = held.load
    after.submit()
    check done[1].finished
    check done[1].codeOf == ecNotReady
    check held.load == before
    after.release()
    # A closed route: its code, nothing dispatched.
    let closing = rc.routeId("k2")
    var h2 = rc.handle(closing)
    var (code3, late) = h2.prepare(req(19), addr done[2])
    check code3 == ecOk
    check rc.close(closing).code == ecOk
    late.submit()
    check done[2].finished
    check done[2].codeOf == ecNotReady
    check held.load == before
    late.release()
    h2.release()
    gate.store(false)
    e.finish()

  test "[IFC-0727] [IMPL-DECISION G52] submission repeats admission: a call the per-call decision denies":
    let e = fixtureEngine(
      config(denying(deny(action = Opt.some(aaCall), operation = "read")))
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    var (code, call) = h.prepare(req(5), addr done[0])
    check code == ecOk
    call.submit()
    check done[0].finished
    check done[0].codeOf == ecNotAuthorised
    call.release()
    h.release()
    e.finish()

  test "[RUN-0829] [IFC-0740] [IMPL-DECISION G174] a route that ends cancels the invocation; closed, it completes with its result; revoked, NOT_AUTHORISED at once":
    let e = fixtureEngine(
      config(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let closing = rc.routeId("k1")
    let revoking = rc.routeId("k2")
    var h1 = rc.handle(closing)
    var h2 = rc.handle(revoking)
    gate.store(true)
    let before = held.load
    var a = h1.started(req(19), addr done[0])
    var b = h2.started(req(19), addr done[1])
    check waitUntil(
      proc(): bool =
        held.load == before + 2
    )
    check rc.close(closing).code == ecOk
    check rc.renew("r", revoking).code == ecNotAuthorised
    check done[1].finished
    check done[1].codeOf == ecNotAuthorised
    check done[0].count.load == 0
    gate.store(false)
    check done[0].finished
    check done[0].codeOf == ecOk
    let r = MeterReadResponse.decode(done[0].responseOf).tryGet
    check r.reading.value == 1 # the provider saw the cancellation
    check waitUntil(
      proc(): bool =
        held.load == before
    )
    sleep(20)
    check done[1].count.load == 1
    a.release()
    b.release()
    h1.release()
    h2.release()
    e.finish()

  test "[RUN-0821] [RUN-0825] events an asynchronous call publishes in its scope reach the preparing handle's subscriptions":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var other = rc.handle(route)
    heard[0].store(0)
    heard[1].store(0)
    discard h.listen(0)
    discard other.listen(1)
    var call = h.started(req(17), addr done[0])
    check done[0].finished
    check done[0].codeOf == ecOk
    check heard[0].load == 1
    check heard[1].load == 0
    call.release()
    h.release()
    other.release()
    e.finish()

suite "run.async: Runtime Control calls (INTERFACE §2.9; RUNTIME §7.5)":
  setup:
    for d in done.mitems:
      d.clear()
  teardown:
    for d in done.mitems:
      d.hold.store(false) # a held callback would keep `close` waiting
    leftover()

  test "[IFC-0712] get_self and establish_route complete asynchronously; start_module completes at ready":
    let e = fixtureEngine(config())
    let (c, rc) = e.startClient()
    var (code, me) = rc.rcPrepare("get_self", [0xA0'u8], addr done[0])
    check code == ecOk
    me.submit()
    check done[0].finished
    check done[0].codeOf == ecOk
    check LogosNSRuntimeControlGetSelfResponse.decode(done[0].responseOf).tryGet.consumer.module_instance_id ==
      c.instance
    me.release()
    discard e.started(meter())
    var (code2, est) = rc.rcPrepare("establish_route", establishReq("k"), addr done[1])
    check code2 == ecOk
    est.submit()
    check done[1].finished
    check done[1].codeOf == ecOk
    est.release()
    slowGate.store(true)
    let s = e.create(slow()).tryGet
    var (code3, start) = rc.rcPrepare(
      "start_module",
      encode(
        LogosNSRuntimeControlStartModuleRequest(
          module: "slow_module", instance: Opt.some(s.instance)
        )
      ).tryGet,
      addr done[2],
    )
    check code3 == ecOk
    start.submit()
    sleep(50)
    check done[2].count.load == 0
    slowGate.store(false)
    check done[2].finished
    check done[2].codeOf == ecOk
    check e.view(s.instance).tryGet.state == msReady
    start.release()
    e.finish()

  test "[IMPL] a completion decided after the consumer's realization ended is suppressed":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (c, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    gate.store(true)
    let before = held.load
    var call = h.started(req(19), addr done[0])
    check waitUntil(
      proc(): bool =
        held.load == before + 1
    )
    h.release() # the module's own duty; the call outlives it (IFC-0720)
    discard e.stop(c.instance)
    check waitUntil(
      proc(): bool =
        e.view(c.instance).tryGet.state == msUnloaded
    )
    # Its realization is gone: no callback begins, and release does not wait.
    call.release()
    gate.store(false)
    check waitUntil(
      proc(): bool =
        held.load == before
    )
    sleep(50)
    check done[0].count.load == 0
    e.finish()

suite "run.async: deferred providers (INTERFACE §2.9.2, §2.9.3)":
  setup:
    for d in done.mitems:
      d.clear()
    resetDeferred()
  teardown:
    for d in done.mitems:
      d.hold.store(false) # a held callback would keep `close` waiting
    leftover()

  test "[IFC-0753] [IFC-0755] [IFC-0773] [IFC-0749] submit, then complete inline or from another thread; current is the invocation's context; synchronous calls still dispatch":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    discard e.started(dmeter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    let expected = h.raw("read", req(5)).response
    check submits.load == 0 # `_MODULE_dispatch`
    var inline = h.started(req(5), addr done[0])
    check done[0].finished
    check done[0].codeOf == ecOk
    check done[0].responseOf == expected
    inline.release()
    mode.store(ord(dmHold))
    var parked = h.started(req(5), addr done[1])
    let (module, inv) = takeHeld()
    check inv != nil
    check done[1].count.load == 0
    settle(module, inv)
    check done[1].finished
    check done[1].codeOf == ecOk
    check done[1].responseOf == expected
    check submits.load == 2
    check submitSawContext.load == 2
    check ownerReleases.load == 2
    parked.release()
    h.release()
    e.finish()

  test "[IFC-0759] [IFC-0760] [IFC-0761] [IFC-0776] one request_cancel once submit returned, with the context current; none after execution release":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    discard e.started(dmeter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    mode.store(ord(dmHold))
    var call = h.started(req(5), addr done[0])
    let (module, inv) = takeHeld()
    call.cancel()
    check done[0].finished
    check done[0].codeOf == ecCancelled
    check waitUntil(
      proc(): bool =
        hooks.load == 1
    )
    check hookSawContext.load == 1
    call.cancel()
    sleep(20)
    check hooks.load == 1
    # Its late completion is consumed and ignored.
    settle(module, inv)
    check ownerReleases.load == 1
    call.release()
    check done[0].count.load == 1
    # Completed and released: a later cancellation reaches no hook.
    var second = h.started(req(5), addr done[1])
    let (m2, i2) = takeHeld()
    settle(m2, i2)
    check done[1].finished
    second.cancel()
    check rc.close(route).code == ecOk
    sleep(20)
    check hooks.load == 1
    second.release()
    h.release()
    e.finish()

  test "[IFC-0764] [IFC-0765] release does not wait for an admitted request_cancel":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    discard e.started(dmeter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    mode.store(ord(dmHold))
    hookGate.store(true)
    var call = h.started(req(5), addr done[0])
    let (module, inv) = takeHeld()
    call.release()
    check done[0].count.load == 1
    check done[0].codeOf == ecCancelled
    check waitUntil(
      proc(): bool =
        inHook.load == 1
    )
    hookGate.store(false)
    check waitUntil(
      proc(): bool =
        inHook.load == 0
    )
    settle(module, inv)
    h.release()
    e.finish()

  test "[IFC-0768] [IFC-0287] [IFC-0757] stopping the provider waits for execution release before destroy":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    let m = e.started(dmeter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    mode.store(ord(dmHold))
    settleOnCancel.store(false)
    var call = h.started(req(5), addr done[0])
    let (module, inv) = takeHeld()
    let gone = destroyed.load
    discard e.stop(m.instance) # answers at its deadline, still stopping
    check destroyed.load == gone
    check done[0].count.load == 0
    # [G174] A route that failed with its provider lets the call complete.
    settle(module, inv)
    check done[0].finished
    check done[0].codeOf == ecOk
    check waitUntil(
      proc(): bool =
        destroyed.load == gone + 1
    )
    call.release()
    h.release()
    e.finish()

  test "[IFC-0757] an invalid completion is MODULE_ERROR and consumes its owner; a second completion is ignored with a diagnostic":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    discard e.started(dmeter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    mode.store(ord(dmHold))
    var bad = h.started(req(5), addr done[0])
    let (m1, i1) = takeHeld()
    settle(m1, i1, invalid = true)
    check done[0].finished
    check done[0].codeOf == ecModule
    check ownerReleases.load == 1
    bad.release()
    var twice = h.started(req(5), addr done[1])
    let (m2, i2) = takeHeld()
    settle(m2, i2, release = false)
    settle(m2, i2)
    check done[1].finished
    check done[1].codeOf == ecOk
    check ownerReleases.load == 3
    check e.diagnostics().anyIt("second completion" in it)
    twice.release()
    h.release()
    e.finish()

  test "[IFC-0782] [IFC-0742] [RUN-0824] [RUN-0829] scoped publication through a deferred invocation's context, before and after its terminal outcome":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    discard e.started(dmeter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    heard[0].store(0)
    discard h.listen(0)
    mode.store(ord(dmHold))
    var call = h.started(req(5), addr done[0])
    let (module, inv) = takeHeld()
    let ctx = inv.context
    proc publish(name: cstring, payload: seq[byte]): ErrorCode =
      toResult(
        ctx.vtable.publish(
          ctx,
          name,
          (
            if payload.len == 0: nil
            else: cast[ptr UncheckedArray[uint8]](unsafeAddr payload[0])
          ),
          csize_t(payload.len),
        )
      ).code

    let valid = encodeCbor(parseDiag("{\"value\": 3}").get)
    check publish("meter.unknown_event", valid) == ecNotAuthorised
    check publish(
      "meter.changed_event", encodeCbor(parseDiag("{\"value\": \"x\"}").get)
    ) == ecInvalidParams
    check publish("meter.changed_event", @[]) == ecInvalidParams
    check publish("", valid) == ecInvalidParams
    check heard[0].load == 0
    check publish("meter.changed_event", valid) == ecOk
    check heard[0].load == 1
    check not ctx.vtable.isCancelled(ctx)
    settle(module, inv, release = false)
    check done[0].finished
    check done[0].codeOf == ecOk
    check publish("meter.changed_event", valid) == ecNotReady
    check heard[0].load == 1
    inv.executionRelease(inv)
    call.release()
    h.release()
    e.finish()
