## The reference fake provider of `lcn.storage_fetch` [DECISIONS G395] (`fetch_fake_module.cddl`;
## `sdk/docs/STORAGE-FETCH.md` §6): what the Package Manager's tests read packages from until
## storage_module serves them (N-4). A test fixture, never packaged.
##
## It has no configuration. A locator `fetch-fake/<size>/<seed>` names `size` bytes of BLAKE3's
## extendable output over `seed`, so a test names any object without sending its bytes; a seed
## beginning `absent-` names an object the fake cannot obtain (`unavailable`); any other locator
## is `invalid-locator`. It starts `starting`, holding nothing. `fetch_fake.set_readiness` moves it
## (publishing the event on a change) and sets the locators it serves while not `ready`;
## `fetch_fake.set_fault` makes one locator answer `unavailable` a number of times, or hold each
## read before it answers. Methods work in every placement, so no in-process hook is needed.

{.used.} # imported by the tests for the C symbols it exports
import std/[locks, os, strutils, tables]
import logos_sdk/crypto/blake3
import ../generated/fetch_fake_module_kit

const
  MaxRead = 1_048_576'u32
    ## [DECISIONS G395] the contract's bound on `length` (STORAGE-FETCH.md §3)
  LocatorPrefix* = "fetch-fake/"
  AbsentPrefix* = "absent-"

type
  Fault = object
    unavailable: uint32 ## answers `unavailable` this many more times
    delayMs: uint32 ## holds each read this long

  FetchFake* = ref object
    services: ModuleServices
    lock: Lock
    readiness: LcnNSStorageFetchReadinessKind
    held: seq[seq[byte]] ## served while not `ready`
    faults: Table[seq[byte], Fault]

  FakeObject* = object ## What a locator names.
    size*: uint64
    seed*: string

func bytesOf*(s: string): seq[byte] =
  for c in s:
    result.add(byte(c))

func fakeLocator*(size: uint64, seed: string): seq[byte] =
  ## The locator of `size` bytes derived from `seed`.
  bytesOf(LocatorPrefix & $size & "/" & seed)

func parseFakeLocator*(locator: openArray[byte]): Opt[FakeObject] =
  ## The object `locator` names, if it is the fake's.
  var s = newString(locator.len)
  for i, b in locator:
    s[i] = char(b)
  if not s.startsWith(LocatorPrefix):
    return Opt.none(FakeObject)
  let rest = s[LocatorPrefix.len .. ^1]
  let slash = rest.find('/')
  if slash <= 0 or slash == rest.high:
    return Opt.none(FakeObject)
  let digits = rest[0 ..< slash]
  if digits.len > 20 or (digits.len > 1 and digits[0] == '0'):
    return Opt.none(FakeObject)
  var size = 0'u64
  for c in digits:
    if c notin {'0' .. '9'}:
      return Opt.none(FakeObject)
    let d = uint64(ord(c) - ord('0'))
    if size > (high(uint64) - d) div 10:
      return Opt.none(FakeObject)
    size = size * 10 + d
  Opt.some(FakeObject(size: size, seed: rest[slash + 1 .. ^1]))

proc fakeBytes*(o: FakeObject, offset: uint64, length: int): seq[byte] =
  ## `length` bytes of the object from `offset` (the caller keeps within its size).
  result = newSeq[byte](length)
  var h: Blake3Hasher
  h.init()
  h.update(o.seed)
  h.finish(offset, result)

proc fakeObject*(locator: openArray[byte]): seq[byte] =
  ## The whole object a fake locator names (tests: the expected bytes).
  let o = parseFakeLocator(locator)
  doAssert o.isSome, "not a fake locator"
  fakeBytes(o.get, 0, int(o.get.size))

func failed(
    code: LcnNSStorageFetchFailureCodeChoiceKind, detail: string
): LcnNSStorageFetchFailure =
  LcnNSStorageFetchFailure(
    code: LcnNSStorageFetchFailureCodeChoice(kind: code), detail: Opt.some(detail)
  )

proc initModule(
    _: type FetchFake, init: ModuleInit
): Result[FetchFake, InvocationFailure] =
  let f = FetchFake(
    services: init.services, readiness: LcnNSStorageFetchReadinessKind.Starting
  )
  initLock(f.lock)
  ok(f)

proc destroyModule(f: FetchFake) =
  deinitLock(f.lock)

proc available(
    f: FetchFake, locator: seq[byte]
): Result[(FakeObject, uint32), LcnNSStorageFetchFailure] =
  ## [DECISIONS G395] After the length: the locator, then
  ## availability (readiness and the object). Spends one injected `unavailable`; the delay
  ## a read holds.
  type K = LcnNSStorageFetchFailureCodeChoiceKind
  let o = parseFakeLocator(locator)
  if o.isNone:
    return err(failed(K.Invalid_locator, "not a fetch-fake locator"))
  withLock f.lock:
    if f.readiness != LcnNSStorageFetchReadinessKind.Ready and locator notin f.held:
      return err(failed(K.Not_ready, "the fake is " & toLowerAscii($f.readiness)))
    if o.get.seed.startsWith(AbsentPrefix):
      return err(failed(K.Unavailable, "the fake cannot obtain this object"))
    var delay = 0'u32
    f.faults.withValue(locator, fault):
      delay = fault.delayMs
      if fault.unavailable > 0:
        fault.unavailable -= 1
        return err(failed(K.Unavailable, "an injected fault"))
    return ok((o.get, delay))

proc stat_object(
    f: FetchFake, request: LcnNSStorageFetchStatObjectRequest
): Result[LcnNSStorageFetchStatObjectResponse, InvocationFailure] =
  type K = LcnNSStorageFetchStatObjectResponseKind
  let a = f.available(request.`object`)
  if a.isErr:
    return ok(
      LcnNSStorageFetchStatObjectResponse(
        kind: K.Map_failure,
        arm_Map_failure:
          LcnNSStorageFetchStatObjectResponseARMapFailureMap(failure: a.error),
      )
    )
  ok(
    LcnNSStorageFetchStatObjectResponse(
      kind: K.Map_size,
      arm_Map_size: LcnNSStorageFetchStatObjectResponseARMapSizeMap(size: a.get[0].size),
    )
  )

proc read_object(
    f: FetchFake, request: LcnNSStorageFetchReadObjectRequest
): Result[LcnNSStorageFetchReadObjectResponse, InvocationFailure] =
  type
    K = LcnNSStorageFetchReadObjectResponseKind
    C = LcnNSStorageFetchFailureCodeChoiceKind

  template refuse(e: LcnNSStorageFetchFailure): untyped =
    return ok(
      LcnNSStorageFetchReadObjectResponse(
        kind: K.Map_failure,
        arm_Map_failure: LcnNSStorageFetchReadObjectResponseARMapFailureMap(failure: e),
      )
    )

  # [DECISIONS G395] The length first, whatever the object.
  if request.length == 0 or request.length > MaxRead:
    refuse(failed(C.Invalid_length, "length must be 1 to 1048576"))
  let a = f.available(request.`object`)
  if a.isErr:
    refuse(a.error)
  let (o, delay) = a.get
  if request.offset > o.size:
    refuse(failed(C.Out_of_range, "offset is past the object's end"))
  if delay > 0:
    sleep(int(delay))
  let n = min(uint64(request.length), o.size - request.offset)
  ok(
    LcnNSStorageFetchReadObjectResponse(
      kind: K.Map_data,
      arm_Map_data: LcnNSStorageFetchReadObjectResponseARMapDataMap(
        data: fakeBytes(o, request.offset, int(n))
      ),
    )
  )

proc fetch_readiness(
    f: FetchFake, request: LcnNSStorageFetchFetchReadinessRequest
): Result[LcnNSStorageFetchFetchReadinessResponse, InvocationFailure] =
  withLock f.lock:
    result = ok(
      LcnNSStorageFetchFetchReadinessResponse(
        readiness: LcnNSStorageFetchReadiness(kind: f.readiness)
      )
    )

proc set_readiness(
    f: FetchFake, request: FetchFakeSetReadinessRequest
): Result[FetchFakeSetReadinessResponse, InvocationFailure] =
  type K = LcnNSStorageFetchReadinessKind
  let next =
    case request.readiness.kind
    of FetchFakeSetReadinessRequestReadinessChoiceKind.Starting: K.Starting
    of FetchFakeSetReadinessRequestReadinessChoiceKind.Ready: K.Ready
    of FetchFakeSetReadinessRequestReadinessChoiceKind.Offline: K.Offline
  # Under the lock, so that events leave in the order of the changes.
  withLock f.lock:
    f.held = request.held
    if next != f.readiness:
      f.readiness = next
      ?f.services.publish(
        LcnNSStorageFetchFetchReadinessChangedEvent(
          readiness: LcnNSStorageFetchReadiness(kind: next)
        )
      )
  ok(FetchFakeSetReadinessResponse())

proc set_fault(
    f: FetchFake, request: FetchFakeSetFaultRequest
): Result[FetchFakeSetFaultResponse, InvocationFailure] =
  withLock f.lock:
    f.faults[request.`object`] =
      Fault(unavailable: request.unavailable, delayMs: request.delay_ms)
  ok(FetchFakeSetFaultResponse())

exportFetchFakeModule(FetchFake)
