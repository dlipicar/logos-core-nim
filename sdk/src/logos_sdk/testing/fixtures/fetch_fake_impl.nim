## The reference fake provider of `lcn.storage_fetch` [DECISIONS G395] (`fetch_fake_module.cddl`;
## `sdk/docs/STORAGE-FETCH.md` §6): what the Package Manager's tests read packages from until
## storage_module serves them (N-4). A test fixture, never packaged.
##
## It has no configuration. A locator `fetch-fake/<size>/<seed>` names `size` bytes of BLAKE3's
## extendable output over `seed`, so a test names any object without sending its bytes; a seed
## beginning `absent-` names an object the fake cannot obtain (`unavailable`). A locator
## `fetch-fake/state/<name>` names the file `<state_dir>/objects/<name>`, which the test writes
## before the start (Tier 5 step 5-3b, Q1 (c)): real documents, such as a catalog and signed
## archives. The name is 1 to 64 bytes from `A-Z a-z 0-9 . _ -` without a leading `.`, so it has
## no separator and reaches nothing outside `objects/`; a missing file is `unavailable`. Any other
## locator is `invalid-locator`. It starts `starting`, holding nothing. `fetch_fake.set_readiness` moves it
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
  StatePrefix* = "fetch-fake/state/"
    ## [Tier 5 step 5-3b, Q1 (c)] a file of the fake's state directory, under `objects/`
  MaxStateName* = 64
  StateNameBytes = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '.', '_', '-'}

type
  Fault = object
    unavailable: uint32 ## answers `unavailable` this many more times
    delayMs: uint32 ## holds each read this long

  FetchFake* = ref object
    services: ModuleServices
    objects: string ## `<state_dir>/objects`, or none without a state directory
    lock: Lock
    readiness: LcnNSStorageFetchReadinessKind
    held: seq[seq[byte]] ## served while not `ready`
    faults: Table[seq[byte], Fault]

  FakeObject* = object ## What a locator names.
    size*: uint64
    seed*: string

  Served = object
    ## What a locator the fake can serve names: derived bytes, or a state file.
    file: string ## the state file's path; none: `derived`
    derived: FakeObject
    size: uint64

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

func stateLocator*(name: string): seq[byte] =
  ## [Q1 (c)] The locator of the state file `objects/<name>`.
  bytesOf(StatePrefix & name)

func stateName*(locator: openArray[byte]): Opt[Opt[string]] =
  ## [Q1 (c), Fable F4] For a locator of the state form, its name when the name
  ## is within the bound, else `some(none)`; `none` for any other locator.
  if locator.len < StatePrefix.len:
    return Opt.none(Opt[string])
  for i, c in StatePrefix:
    if locator[i] != byte(c):
      return Opt.none(Opt[string])
  let n = locator.len - StatePrefix.len
  if n < 1 or n > MaxStateName or locator[StatePrefix.len] == byte('.'):
    return Opt.some(Opt.none(string))
  var name = newString(n)
  for i in 0 ..< n:
    let c = char(locator[StatePrefix.len + i])
    if c notin StateNameBytes:
      return Opt.some(Opt.none(string))
    name[i] = c
  Opt.some(Opt.some(name))

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
    services: init.services,
    objects: (if init.stateDir.isSome: init.stateDir.get / "objects"
    else: ""),
    readiness: LcnNSStorageFetchReadinessKind.Starting,
  )
  initLock(f.lock)
  ok(f)

proc destroyModule(f: FetchFake) =
  deinitLock(f.lock)

proc available(
    f: FetchFake, locator: seq[byte]
): Result[(Served, uint32), LcnNSStorageFetchFailure] =
  ## [DECISIONS G395] After the length: the locator, then
  ## availability (readiness and the object). Spends one injected `unavailable`; the delay
  ## a read holds.
  type K = LcnNSStorageFetchFailureCodeChoiceKind
  let state = stateName(locator)
  var served: Served
  if state.isSome:
    if state.get.isNone:
      return err(failed(K.Invalid_locator, "not a fetch-fake state name"))
    served.file = state.get.get
  else:
    let o = parseFakeLocator(locator)
    if o.isNone:
      return err(failed(K.Invalid_locator, "not a fetch-fake locator"))
    served.derived = o.get
    served.size = o.get.size
  var delay = 0'u32
  withLock f.lock:
    if f.readiness != LcnNSStorageFetchReadinessKind.Ready and locator notin f.held:
      return err(failed(K.Not_ready, "the fake is " & toLowerAscii($f.readiness)))
    if served.file.len == 0 and served.derived.seed.startsWith(AbsentPrefix):
      return err(failed(K.Unavailable, "the fake cannot obtain this object"))
    f.faults.withValue(locator, fault):
      delay = fault.delayMs
      if fault.unavailable > 0:
        fault.unavailable -= 1
        return err(failed(K.Unavailable, "an injected fault"))
  if served.file.len > 0:
    # [Q1 (c)] A regular file of `objects/`, its size as it is now.
    if f.objects.len == 0:
      return err(failed(K.Unavailable, "the fake has no state directory"))
    served.file = f.objects / served.file
    try:
      if getFileInfo(served.file, followSymlink = false).kind != pcFile:
        return err(failed(K.Unavailable, "the fake holds no such file"))
      served.size = uint64(getFileSize(served.file))
    except OSError:
      return err(failed(K.Unavailable, "the fake holds no such file"))
  ok((served, delay))

proc servedBytes(
    s: Served, offset: uint64, length: int
): Result[seq[byte], LcnNSStorageFetchFailure] =
  if s.file.len == 0:
    return ok(fakeBytes(s.derived, offset, length))
  var data = newSeq[byte](length)
  try:
    var file = open(s.file)
    defer:
      file.close()
    file.setFilePos(int64(offset))
    if length > 0 and file.readBytes(data, 0, length) != length:
      return err(
        failed(
          LcnNSStorageFetchFailureCodeChoiceKind.Unavailable,
          "the file changed while read",
        )
      )
  except IOError, OSError:
    return err(
      failed(
        LcnNSStorageFetchFailureCodeChoiceKind.Unavailable, "the file could not be read"
      )
    )
  ok(data)

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
  let data = o.servedBytes(request.offset, int(n))
  if data.isErr:
    refuse(data.error)
  ok(
    LcnNSStorageFetchReadObjectResponse(
      kind: K.Map_data,
      arm_Map_data: LcnNSStorageFetchReadObjectResponseARMapDataMap(data: data.get),
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
