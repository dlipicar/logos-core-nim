## The conformance harness of `lcn.storage_fetch` [DECISIONS G395] (`sdk/docs/STORAGE-FETCH.md`
## §7): the checks every provider of the contract passes, over route handles the caller
## materialized, wherever it can reach the provider. The SDK's suite runs it over its in-process
## route, core's under a test Runtime with the provider direct and hosted, and N-4 against
## storage_module. Each check returns what it found wrong; nothing means it passed.
##
## Two parts. The call checks run everywhere. The readiness checks need handles that subscribe;
## with a driver (the fake's `set_readiness`) they move the provider through every state, without
## one they observe it. A provider may serve objects it holds while not `ready` and may accept
## every locator, so neither is checked.

import std/[locks, monotimes, os, strutils, times, typedthreads]
import results
import logos_sdk/abi/types
import logos_sdk/crypto/blake3
import logos_sdk/contracts/generated/lcn_NS_storage_fetch_calls

export lcn_NS_storage_fetch_calls

const
  MaxReadLength* = 1_048_576'u32 ## [DECISIONS G395] the bound on `length`
  ReadinessEvent* = "lcn.storage_fetch.fetch_readiness_changed_event"

type
  FetchReadiness* = LcnNSStorageFetchReadinessKind
  FetchFailure* = LcnNSStorageFetchFailureCodeChoiceKind

  FetchObject* = object ## An object the provider serves.
    locator*: seq[byte]
    size*: uint64
    digest*: Blake3Digest ## BLAKE3 of the whole object

  FetchFixture* = object
    objects*: seq[FetchObject]
      ## at least two; the first is read by four handles at once, and is the one a
      ## readiness driver holds while not `ready`
    absent*: seq[byte] ## a locator the provider reads as valid but cannot obtain

  ReadinessDriver* = proc(
    readiness: FetchReadiness, held: seq[seq[byte]]
  ): Result[void, string] {.closure, gcsafe, raises: [].}

  FetchTarget* = object
    handles*: seq[ptr LogosRouteHandle]
      ## at least four materialized handles to one provider; the first makes the
      ## sequential calls (INTERFACE l.1935)
    subscribes*: bool ## the handles take subscriptions: the readiness checks run
    drive*: Opt[ReadinessDriver]
    wait*: Duration ## the bound on a wait for an event or a state

func objectOf*(locator, bytes: openArray[byte]): FetchObject =
  FetchObject(locator: @locator, size: uint64(bytes.len), digest: blake3(bytes))

# Calls ------------------------------------------------------------------------------------

func describe(f: InvocationFailure): string =
  "invocation failed: " & $f.code & (if f.message.isSome: " " & f.message.get
  else: "")

proc stat*(
    h: ptr LogosRouteHandle, locator: seq[byte]
): Result[LcnNSStorageFetchStatObjectResponse, string] =
  invoke(h, LcnNSStorageFetchStatObjectRequest(`object`: locator)).mapErr(describe)

proc read*(
    h: ptr LogosRouteHandle, locator: seq[byte], offset: uint64, length: uint32
): Result[LcnNSStorageFetchReadObjectResponse, string] =
  invoke(
    h,
    LcnNSStorageFetchReadObjectRequest(
      `object`: locator, offset: offset, length: length
    ),
  )
    .mapErr(describe)

proc readiness*(h: ptr LogosRouteHandle): Result[FetchReadiness, string] =
  let r = ?invoke(h, LcnNSStorageFetchFetchReadinessRequest()).mapErr(describe)
  ok(r.readiness.kind)

func failureOf*(r: LcnNSStorageFetchReadObjectResponse): Opt[FetchFailure] =
  if r.kind == LcnNSStorageFetchReadObjectResponseKind.Map_failure:
    Opt.some(r.arm_Map_failure.failure.code.kind)
  else:
    Opt.none(FetchFailure)

func failureOf*(r: LcnNSStorageFetchStatObjectResponse): Opt[FetchFailure] =
  if r.kind == LcnNSStorageFetchStatObjectResponseKind.Map_failure:
    Opt.some(r.arm_Map_failure.failure.code.kind)
  else:
    Opt.none(FetchFailure)

proc readAll*(
    h: ptr LogosRouteHandle, o: FetchObject, problems: var seq[string]
): Opt[Blake3Digest] =
  ## Reads `o` in steps of the largest length; each step must answer exactly what is left
  ## up to that length.
  var hasher: Blake3Hasher
  hasher.init()
  var offset = 0'u64
  while offset < o.size:
    let r = h.read(o.locator, offset, MaxReadLength)
    if r.isErr:
      problems.add("read at " & $offset & ": " & r.error)
      return Opt.none(Blake3Digest)
    if r.get.failureOf.isSome:
      problems.add("read at " & $offset & " answered " & $r.get.failureOf.get)
      return Opt.none(Blake3Digest)
    let data = r.get.arm_Map_data.data
    let want = min(uint64(MaxReadLength), o.size - offset)
    if uint64(data.len) != want:
      problems.add("read at " & $offset & " gave " & $data.len & " bytes, not " & $want)
      return Opt.none(Blake3Digest)
    hasher.update(data)
    offset += want
  Opt.some(hasher.finish())

proc expectFailure(
    problems: var seq[string],
    what: string,
    r: Result[LcnNSStorageFetchReadObjectResponse, string],
    want: FetchFailure,
) =
  if r.isErr:
    problems.add(what & ": " & r.error)
  elif r.get.failureOf != Opt.some(want):
    problems.add(what & " did not answer " & $want)

type ReadJob = object
  handle: ptr LogosRouteHandle
  target: FetchObject
  done: bool
  digest: Blake3Digest

proc readJob(job: ptr ReadJob) {.thread.} =
  var problems: seq[string]
  let d = job.handle.readAll(job.target, problems)
  if d.isSome:
    job.digest = d.get
    job.done = true

proc callChecks*(t: FetchTarget, f: FetchFixture): seq[string] =
  ## Sizes, whole reads, the end, the length rule (checked before anything else), an object
  ## the provider cannot obtain, and four reads of one object at once on four handles.
  doAssert t.handles.len >= 4 and f.objects.len >= 2
  let h = t.handles[0]
  for o in f.objects:
    let s = h.stat(o.locator)
    if s.isErr:
      result.add("stat: " & s.error)
    elif s.get.failureOf.isSome:
      result.add("stat answered " & $s.get.failureOf.get)
    elif s.get.arm_Map_size.size != o.size:
      result.add("stat gave " & $s.get.arm_Map_size.size & ", not " & $o.size)
    let d = h.readAll(o, result)
    if d.isSome and d.get != o.digest:
      result.add("the object read is not the object")
    let atEnd = h.read(o.locator, o.size, 1)
    if atEnd.isErr or atEnd.get.failureOf.isSome or atEnd.get.arm_Map_data.data.len != 0:
      result.add("a read at the end did not answer empty data")
    result.expectFailure(
      "a read past the end", h.read(o.locator, o.size + 1, 1), FetchFailure.Out_of_range
    )
  let first = f.objects[0]
  for (length, what) in [(0'u32, "length 0"), (MaxReadLength + 1, "length 1 MiB + 1")]:
    result.expectFailure(
      what, h.read(first.locator, 0, length), FetchFailure.Invalid_length
    )
    result.expectFailure(
      what & " of an absent object",
      h.read(f.absent, 0, length),
      FetchFailure.Invalid_length,
    )
  result.expectFailure(
    "a read of an absent object", h.read(f.absent, 0, 1), FetchFailure.Unavailable
  )
  let s = h.stat(f.absent)
  if s.isErr or s.get.failureOf != Opt.some(FetchFailure.Unavailable):
    result.add("the stat of an absent object did not answer unavailable")
  var
    jobs: array[4, ReadJob]
    threads: array[4, Thread[ptr ReadJob]]
  for i in 0 .. 3:
    jobs[i] = ReadJob(handle: t.handles[i], target: first)
    createThread(threads[i], readJob, addr jobs[i])
  joinThreads(threads)
  for i in 0 .. 3:
    if not jobs[i].done or jobs[i].digest != first.digest:
      result.add("concurrent read " & $i & " did not read the object")

# FetchReadiness --------------------------------------------------------------------------------

type Heard = object ## The readiness events one subscription delivered.
  lock: Lock
  states: seq[FetchReadiness]
  bad: int ## deliveries that did not decode

var heard: Heard
initLock(heard.lock)

proc onReadiness(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let ev =
    if len > 0:
      LcnNSStorageFetchFetchReadinessChangedEvent.decode(
        toOpenArray(data, 0, int(len) - 1)
      )
    else:
      LcnNSStorageFetchFetchReadinessChangedEvent.decode([])
  {.cast(gcsafe).}:
    withLock heard.lock:
      if ev.isOk and $name == ReadinessEvent:
        heard.states.add(ev.get.readiness.kind)
      else:
        heard.bad += 1

proc heardSoFar(): (seq[FetchReadiness], int) =
  {.cast(gcsafe).}:
    withLock heard.lock:
      result = (heard.states, heard.bad)

proc waitFor(t: FetchTarget, cond: proc(): bool {.closure, gcsafe, raises: [].}): bool =
  let until = getMonoTime() + t.wait
  while not cond():
    if getMonoTime() > until:
      return false
    sleep(5)
  true

proc readinessChecks*(t: FetchTarget, f: FetchFixture): seq[string] =
  ## [DECISIONS G136, G395] Subscribe, then query; one event per change; while not `ready`, a
  ## read of an object the provider does not hold answers `not-ready`. With a driver: through
  ## `starting`, `ready`, `offline` and back to `ready`, which it leaves the provider in.
  ## Without one: what the provider is, and its next change if it is not `ready`.
  if not t.subscribes:
    return @["the handles take no subscriptions"]
  let h = t.handles[0]
  {.cast(gcsafe).}:
    withLock heard.lock:
      heard.states.setLen(0)
      heard.bad = 0
  var id: LogosSubscriptionId
  let sub = h.vtable.subscribe(h, cstring(ReadinessEvent), onReadiness, nil, addr id)
  if sub.code != 0:
    return @["subscribe failed with code " & $sub.code]
  defer:
    discard h.vtable.unsubscribe(h, id)
  let now = h.readiness()
  if now.isErr:
    return @["fetch_readiness: " & now.error]
  var
    current = now.get
    events = 0

  proc settles(
      t: FetchTarget, n: int, want: FetchReadiness, problems: var seq[string]
  ) =
    ## `n` events in all so far, the last `want`, and no other in a further moment.
    let ok = t.waitFor(
      proc(): bool =
        heardSoFar()[0].len >= n
    )
    sleep(50)
    let (states, bad) = heardSoFar()
    if not ok or states.len != n:
      problems.add("expected " & $n & " readiness events in all, heard " & $states.len)
    elif n > 0 and states[^1] != want:
      problems.add("the last readiness event was " & $states[^1] & ", not " & $want)
    if bad > 0:
      problems.add($bad & " deliveries were not readiness events")

  proc notReady(what: string, locator: seq[byte], problems: var seq[string]) =
    let r = h.read(locator, 0, 1)
    if r.isErr or r.get.failureOf != Opt.some(FetchFailure.Not_ready):
      problems.add(what & " did not answer not-ready")

  if t.drive.isNone:
    if current != FetchReadiness.Ready:
      notReady("a read while " & $current, f.absent, result)
      let reached = t.waitFor(
        proc(): bool =
          let s = heardSoFar()[0]
          s.len > 0 and s[^1] == FetchReadiness.Ready
      )
      if not reached:
        result.add("the provider did not become ready")
    return
  let drive = t.drive.get
  let (held, other) = (f.objects[0], f.objects[1])

  proc move(to: FetchReadiness, holding: seq[seq[byte]], problems: var seq[string]) =
    let r = drive(to, holding)
    if r.isErr:
      problems.add("the driver failed: " & r.error)
      return
    if to != current:
      inc events
      current = to
    settles(t, events, to, problems)
    let q = h.readiness()
    if q.isErr or q.get != to:
      problems.add("fetch_readiness did not answer " & $to)

  move(FetchReadiness.Starting, @[held.locator], result)
  let r = h.read(held.locator, 0, 1)
  if r.isErr or r.get.failureOf.isSome:
    result.add("a held object was not served while starting")
  notReady("an object not held, while starting,", other.locator, result)
  move(FetchReadiness.Ready, @[], result)
  if h.read(other.locator, 0, 1).isErr:
    result.add("a read failed once ready")
  move(FetchReadiness.Ready, @[], result) # no change, no event
  move(FetchReadiness.Offline, @[], result)
  notReady("a read while offline", held.locator, result)
  move(FetchReadiness.Ready, @[], result)
