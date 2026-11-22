## `lcn.storage_fetch` [DECISIONS G395] (`sdk/src/logos_sdk/contracts/lcn_storage_fetch.cddl`,
## `sdk/docs/STORAGE-FETCH.md`): the document and its root, the generated codecs, and the
## conformance harness's call checks (`logos_sdk/testing/storagefetch`) against the reference
## fake over the SDK's in-process route (`logos_sdk/testing/testroute`). That route takes no
## subscriptions, so the readiness checks run in core's `tests/test_storage_fetch.nim`, under a
## test Runtime; here the fake's methods are called and its publications read where the kit
## records them.

import std/[locks, sequtils, strutils, times]
import unittest2
import logos_sdk/iface/accept
import logos_sdk/testing/storagefetch
import logos_sdk/contracts/generated/lcn_storage_fetch_root
from logos_sdk/testing/generated/fetch_fake_module_calls import
  invoke, FetchFakeSetReadinessRequest, FetchFakeSetReadinessRequestReadinessChoice,
  FetchFakeSetReadinessRequestReadinessChoiceKind, FetchFakeSetFaultRequest
import logos_sdk/testing/fixtures/fetch_fake_impl
import logos_sdk/testing/testroute
import ./support/genfixtures

# The fake, in this process ----------------------------------------------------------------

proc fakeInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.
  importc: "logos_fetch_fake_module_MODULE_init", cdecl, gcsafe, raises: []
.}

proc fakeDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_fetch_fake_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc fakeDispatch(
  module: ptr LogosModuleContext,
  methodName: cstring,
  params: ptr UncheckedArray[uint8],
  paramsLen: csize_t,
  outResponse: ptr ptr UncheckedArray[uint8],
  outResponseLen: ptr csize_t,
): LogosResult {.
  importc: "logos_fetch_fake_module_MODULE_dispatch", cdecl, gcsafe, raises: []
.}

proc fakeFree(
  module: ptr LogosModuleContext, p: pointer
) {.importc: "logos_fetch_fake_module_MODULE_free", cdecl, gcsafe, raises: [].}

proc started(): ptr LogosModuleContext =
  var i = input()
  doAssert fakeInit(addr i, addr result).code == 0

proc routes(ctx: ptr LogosModuleContext): seq[ptr TestRoute] =
  for _ in 0 .. 3:
    result.add(newRoute(rmDirect, ctx, fakeDispatch, fakeFree))

proc handles(rs: seq[ptr TestRoute]): seq[ptr LogosRouteHandle] =
  for r in rs:
    result.add(r.routeHandle)

proc setReadiness(
    h: ptr LogosRouteHandle,
    to: FetchFakeSetReadinessRequestReadinessChoiceKind,
    held: seq[seq[byte]] = @[],
): bool =
  invoke(
    h,
    FetchFakeSetReadinessRequest(
      readiness: FetchFakeSetReadinessRequestReadinessChoice(kind: to), held: held
    ),
  ).isOk

proc readinessPublished(): seq[string] =
  ## The readiness events the fake published, in order, by their state.
  withLock publishedLock:
    for (name, payload, _) in published:
      if name == ReadinessEvent:
        let ev = LcnNSStorageFetchFetchReadinessChangedEvent.decode(payload)
        result.add(
          if ev.isOk:
            $ev.get.readiness.kind
          else:
            "undecodable"
        )

let
  big = fakeLocator(3 * 1_048_576 + 7, "big")
  small = fakeLocator(1000, "small")
  absent = fakeLocator(10, AbsentPrefix & "x")
  fixture = FetchFixture(
    objects: @[objectOf(big, fakeObject(big)), objectOf(small, fakeObject(small))],
    absent: absent,
  )

type RK = FetchFakeSetReadinessRequestReadinessChoiceKind

# The document -----------------------------------------------------------------------------

suite "lcn.storage_fetch: the document (G395)":
  test "an interface contract whose root is the committed one, computed from its text; the fake implements it":
    let doc = readFile(storageFetchDocument)
    let set = acceptContractSet(doc)
    check set.isOk
    if set.isOk:
      check set.get.primary.model.role == srInterface
      check set.get.primary.root == LcnStorageFetchRoot
      check set.get.primary.model.methods.len == 3
      check set.get.primary.model.events.len == 1
    let fake = readFile(fetchFakeDocument)
    check implementsOf(fake) == @[LcnStorageFetchRoot]
    check acceptContractSet(fake, [doc]).isOk
    # Any change to the contract's text changes its root, and the fake's literal goes stale
    # loudly: its set no longer accepts.
    let changed = doc.replace("\"offline\"", "\"lost\"")
    check acceptContractSet(changed).get.primary.root != LcnStorageFetchRoot
    check acceptContractSet(fake, [changed]).isErr

  test "sdk/docs/STORAGE-FETCH.md shows the document verbatim":
    let doc = readFile(storageFetchDocument)
    check ("```cddl\n" & doc & "```\n") in readFile("sdk/docs/STORAGE-FETCH.md")

  test "requests and responses round-trip, and each response arm decodes to its own":
    type
      SK = LcnNSStorageFetchStatObjectResponseKind
      DK = LcnNSStorageFetchReadObjectResponseKind

    let req = LcnNSStorageFetchReadObjectRequest(`object`: big, offset: 7, length: 1)
    let back = LcnNSStorageFetchReadObjectRequest.decode(encode(req).get).get
    check back.`object` == big and back.offset == 7 and back.length == 1
    let size = LcnNSStorageFetchStatObjectResponse(
      kind: SK.Map_size,
      arm_Map_size: LcnNSStorageFetchStatObjectResponseARMapSizeMap(size: 5),
    )
    let s = LcnNSStorageFetchStatObjectResponse.decode(encode(size).get).get
    check s.kind == SK.Map_size and s.arm_Map_size.size == 5
    for code in FetchFailure:
      let f =
        LcnNSStorageFetchFailure(code: LcnNSStorageFetchFailureCodeChoice(kind: code))
      let r = LcnNSStorageFetchReadObjectResponse(
        kind: DK.Map_failure,
        arm_Map_failure: LcnNSStorageFetchReadObjectResponseARMapFailureMap(failure: f),
      )
      let d = LcnNSStorageFetchReadObjectResponse.decode(encode(r).get).get
      check d.failureOf == Opt.some(code)
    let empty = LcnNSStorageFetchReadObjectResponse(
      kind: DK.Map_data, arm_Map_data: LcnNSStorageFetchReadObjectResponseARMapDataMap()
    )
    let e = LcnNSStorageFetchReadObjectResponse.decode(encode(empty).get).get
    check e.kind == DK.Map_data and e.arm_Map_data.data.len == 0
    for r in FetchReadiness:
      let ev = LcnNSStorageFetchFetchReadinessChangedEvent(
        readiness: LcnNSStorageFetchReadiness(kind: r)
      )
      check LcnNSStorageFetchFetchReadinessChangedEvent.decode(encode(ev).get).get.readiness.kind ==
        r

  test "the schema refuses an empty or 4,097-byte locator, a length above uint32 and 1 MiB + 1 of data":
    check encode(LcnNSStorageFetchStatObjectRequest(`object`: newSeq[byte](4096))).isOk
    check encode(LcnNSStorageFetchStatObjectRequest(`object`: newSeq[byte](4097))).isErr
    check encode(LcnNSStorageFetchStatObjectRequest()).isErr
    check LcnNSStorageFetchReadObjectRequest.decode(
      diag("""{"object": h'01', "offset": 0, "length": 4294967295}""")
    ).isOk
    check LcnNSStorageFetchReadObjectRequest.decode(
      diag("""{"object": h'01', "offset": 0, "length": 4294967296}""")
    ).isErr
    let over = LcnNSStorageFetchReadObjectResponse(
      kind: LcnNSStorageFetchReadObjectResponseKind.Map_data,
      arm_Map_data:
        LcnNSStorageFetchReadObjectResponseARMapDataMap(data: newSeq[byte](1_048_577)),
    )
    check encode(over).isErr

# The fake over the in-process route ---------------------------------------------------------

suite "lcn.storage_fetch: the reference fake over the in-process route (G395)":
  setup:
    let ctx = started()
    let rs = routes(ctx)
    let hs = rs.handles
    let h = hs[0]
    withLock publishedLock:
      published.setLen(0)

  teardown:
    for r in rs:
      dispose(r)
    fakeDestroy(ctx)

  test "the harness's call checks pass once it is ready":
    check h.readiness().get == FetchReadiness.Starting
    check h.setReadiness(RK.Ready)
    let problems =
      callChecks(FetchTarget(handles: hs, wait: initDuration(seconds = 10)), fixture)
    check problems.len == 0
    for p in problems:
      checkpoint p

  test "it starts `starting`; held objects are served before `ready`, others answer not-ready; one event per change":
    check h.setReadiness(RK.Starting, @[small])
    check readinessPublished().len == 0 # no change
    check h.read(small, 0, 10).get.failureOf.isNone
    check h.read(big, 0, 10).get.failureOf == Opt.some(FetchFailure.Not_ready)
    check h.stat(big).get.failureOf == Opt.some(FetchFailure.Not_ready)
    check h.read(absent, 0, 10).get.failureOf == Opt.some(FetchFailure.Not_ready)
    check h.setReadiness(RK.Ready)
    check h.setReadiness(RK.Ready)
    check h.read(big, 0, 10).get.failureOf.isNone
    check h.setReadiness(RK.Offline)
    check h.read(small, 0, 10).get.failureOf == Opt.some(FetchFailure.Not_ready)
    check h.setReadiness(RK.Ready)
    check readinessPublished() == @["Ready", "Offline", "Ready"]
    check h.readiness().get == FetchReadiness.Ready

  test "an injected fault answers unavailable N times, and the read resumes from the same offset":
    check h.setReadiness(RK.Ready)
    let first = h.read(big, 0, MaxReadLength).get
    check first.failureOf.isNone
    check invoke(
      h, FetchFakeSetFaultRequest(`object`: big, unavailable: 2, delay_ms: 0)
    ).isOk
    let offset = uint64(MaxReadLength)
    check h.read(big, offset, MaxReadLength).get.failureOf ==
      Opt.some(FetchFailure.Unavailable)
    check h.stat(big).get.failureOf == Opt.some(FetchFailure.Unavailable)
    let next = h.read(big, offset, MaxReadLength).get
    check next.failureOf.isNone
    let whole = fakeObject(big)
    check next.arm_Map_data.data ==
      whole[int(offset) ..< int(offset) + int(MaxReadLength)]
    check first.arm_Map_data.data == whole[0 ..< int(MaxReadLength)]

  test "the fake's locator encoding: anything else is invalid-locator, and the length is checked first":
    check h.setReadiness(RK.Ready)
    for bad in [
      "fetch-fake/x/seed", "fetch-fake/5/", "fetch-fake//seed", "fetch-fake/05/seed",
      "fetch-fake/99999999999999999999/seed", "other", "fetch-fake/5",
    ]:
      checkpoint bad
      check h.read(bytesOf(bad), 0, 1).get.failureOf ==
        Opt.some(FetchFailure.Invalid_locator)
      check h.stat(bytesOf(bad)).get.failureOf == Opt.some(FetchFailure.Invalid_locator)
      check h.read(bytesOf(bad), 0, 0).get.failureOf ==
        Opt.some(FetchFailure.Invalid_length)
    check h.stat(fakeLocator(0, "zero")).get.arm_Map_size.size == 0
    check h.read(fakeLocator(0, "zero"), 0, 1).get.arm_Map_data.data.len == 0
    check h.read(fakeLocator(5, "a/b"), 0, 5).get.arm_Map_data.data ==
      fakeObject(fakeLocator(5, "a/b"))

  test "the harness reports a provider that serves other bytes or another size":
    check h.setReadiness(RK.Ready)
    var wrong = fixture
    wrong.objects[0].size += 1
    wrong.objects[1].digest[0] = wrong.objects[1].digest[0] xor 1
    let problems =
      callChecks(FetchTarget(handles: hs, wait: initDuration(seconds = 10)), wrong)
    check problems.anyIt("stat gave" in it)
    check problems.anyIt("not the object" in it)
