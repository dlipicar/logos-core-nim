## Runtime Control observation (step 7a; DECISIONS I86): `list_modules` and
## `list_routes` with their snapshots and cursors (RUNTIME §9.3 l.3350-3413),
## `get_execution_summary` (l.3513-3535) with the realization it reports
## (G227), `describe_provider` (§2.4 l.448-458) and the constant permission
## settings of direct mode (l.2526-2604; G229).
##
## The consumer is the route fixture's client module, so the test calls
## Runtime Control as that module. `test_observe_ca` runs these cases with a
## Capability Authority bound, and adds the cases its narrowing needs.

import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/runtime/artifact
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/codegen/nimrt
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, provider, surface]
import ../src/logos_core/iface/common_types
import ../src/logos_core/pins
import ./support/[kitbuild, kitruntime]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work =
    repo / "build" / (when declared(caParity): "observe_ca" else: "observe") / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# Requests -----------------------------------------------------------------------------

proc modules(
    rc: ptr LogosRuntimeControlBinding,
    module = Opt.none(string),
    instance = Opt.none(string),
    limit = Opt.none(uint16),
    cursor = Opt.none(string),
): RcResult =
  rcCall(
    rc,
    "list_modules",
    encode(
      LogosNSRuntimeControlListModulesRequest(
        module: module, instance: instance, limit: limit, cursor: cursor
      )
    ).tryGet,
  )

proc listed(r: RcResult): LogosNSRuntimeControlListModulesResponse =
  check r.code == ecOk
  if r.code == ecOk:
    result = LogosNSRuntimeControlListModulesResponse.decode(r.response).tryGet

func ids(r: LogosNSRuntimeControlListModulesResponse): seq[string] =
  r.modules.mapIt(it.instance.get(""))

proc routeList(
    rc: ptr LogosRuntimeControlBinding,
    module = Opt.none(string),
    provider = Opt.none(LogosNSRuntimeModuleProviderAddress),
    limit = Opt.none(uint16),
    cursor = Opt.none(string),
): RcResult =
  rcCall(
    rc,
    "list_routes",
    encode(
      LogosNSRuntimeControlListRoutesRequest(
        module: module, provider: provider, limit: limit, cursor: cursor
      )
    ).tryGet,
  )

proc routesListed(r: RcResult): LogosNSRuntimeControlListRoutesResponse =
  check r.code == ecOk
  if r.code == ecOk:
    result = LogosNSRuntimeControlListRoutesResponse.decode(r.response).tryGet

proc address(
    e: Engine, instance: string, runtime = ""
): LogosNSRuntimeModuleInstanceAddress =
  LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: (if runtime.len > 0: runtime else: e.runtimeInstanceId),
    module_instance_id: instance,
  )

proc summaryOf(
    rc: ptr LogosRuntimeControlBinding, target: LogosNSRuntimeModuleInstanceAddress
): RcResult =
  rcCall(
    rc,
    "get_execution_summary",
    encode(LogosNSRuntimeControlGetExecutionSummaryRequest(target: target)).tryGet,
  )

proc summarized(r: RcResult): LogosNSRuntimeControlGetExecutionSummaryResponse =
  check r.code == ecOk
  if r.code == ecOk:
    result = LogosNSRuntimeControlGetExecutionSummaryResponse.decode(r.response).tryGet

proc realizationOf(
    rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string
): LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind =
  rc.summaryOf(e.address(instance)).summarized.realization.kind

proc describeOf(
    rc: ptr LogosRuntimeControlBinding, provider: LogosNSRuntimeModuleProviderAddress
): RcResult =
  rcCall(
    rc,
    "describe_provider",
    encode(LogosNSRuntimeControlDescribeProviderRequest(provider: provider)).tryGet,
  )

proc settingsOf(
    rc: ptr LogosRuntimeControlBinding, target: LogosNSRuntimeModuleInstanceAddress
): RcResult =
  rcCall(
    rc,
    "get_permission_settings",
    encode(LogosNSRuntimeControlGetPermissionSettingsRequest(target: target)).tryGet,
  )

proc updateOf(
    rc: ptr LogosRuntimeControlBinding,
    target: LogosNSRuntimeModuleInstanceAddress,
    revision: uint64,
    permissions: seq[LogosNSRuntimeControlPermissionSetting] = @[],
): RcResult =
  rcCall(
    rc,
    "update_permission_settings",
    encode(
      LogosNSRuntimeControlUpdatePermissionSettingsRequest(
        target: target, expected_revision: revision, permissions: permissions
      )
    ).tryGet,
  )

proc retireOf(
    rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string
): RcResult =
  rcCall(
    rc,
    "retire_module",
    encode(
      LogosNSRuntimeControlRetireModuleRequest(
        target: e.address(instance),
        expected_execution_revision: e.view(instance).tryGet.execution.revision,
      )
    ).tryGet,
  )

proc latestClient(): ptr LogosRuntimeControlBinding =
  ## The Runtime Control binding of the latest client initialization.
  cast[ptr LogosRuntimeControlBinding](clients[(clientInits.load - 1) mod MaxClients].load)

proc meterSurface(): seq[byte] =
  ## The bytes the meter kit's `_MODULE_call_surface` returns.
  for (name, p) in meterModuleStaticSymbols():
    if name == "logos_meter_module_MODULE_call_surface":
      let f =
        cast[proc(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].}](p)
      var n: csize_t
      let d = cast[ptr UncheckedArray[uint8]](f(addr n))
      for i in 0 ..< int(n):
        result.add(d[i])

const ForeignRuntime = "00000000-0000-4000-8000-000000000000"

func some16(n: int): Opt[uint16] =
  Opt.some(uint16(n))

func someText(s: string): Opt[string] =
  Opt.some(s)

proc slows(e: Engine, names: varargs[string]) =
  for n in names:
    discard e.create(slow(), n).tryGet

# list_modules -------------------------------------------------------------------------

suite "run.rc: list_modules (RUNTIME §9.3 l.3350-3357, l.3372-3413)":
  test "[RUN-0282] [RUN-0283] [RUN-0401] [RUN-0414] [RUN-0415] [RUN-0627] [RUN-0972] [RUN-0973] [RUN-0975] every local instance, instance keys before provider keys, each as one committed view":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    e.slows("s")
    let (_, rc) = e.startClient("c")
    let got = rc.modules().listed
    check got.next_cursor.isNone
    # [SPEC RUNTIME l.3407-3411] Instance-keyed records by instance id, then
    # provider-keyed ones by provider id (one Runtime).
    var plain, keyed: seq[(string, string)]
    for v in e.list():
      if v.providerId.len > 0:
        keyed.add((v.providerId, v.instance))
      else:
        plain.add((v.instance, v.instance))
    plain.sort()
    keyed.sort()
    check got.ids == (plain & keyed).mapIt(it[1])
    let rt = e.runtimeInstanceId
    for r in got.modules:
      let v = e.view(r.instance.get).tryGet
      check r.module == v.module
      check r.execution.get.revision == v.execution.revision
      check r.mode.kind == LogosNSRuntimeControlModeKind.Direct
      check r.remote.isNone
      if v.providerId.len > 0:
        check r.provider == Opt.some(providerAddress(v.providerId, Opt.some(rt)))
      else:
        check r.provider.isNone
    let m = got.modules.filterIt(it.instance == Opt.some("m"))
    check m.len == 1
    check m[0].primary_contract.get.schema_root == @meterRoot
    check m[0].state.kind == LogosNSRuntimeControlStateKind.Ready
    check m[0].failure.isNone
    let s = got.modules.filterIt(it.instance == Opt.some("s"))
    check s.len == 1 and s[0].state.kind == LogosNSRuntimeControlStateKind.Unloaded
    e.finish()

  test "[RUN-0953] the module and instance filters both match":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    e.slows("s", "t")
    let (_, rc) = e.startClient("c")
    check rc.modules(module = someText("meter_module")).listed.ids == @["m"]
    check rc.modules(instance = someText("t")).listed.ids == @["t"]
    check rc.modules(module = someText("slow_module")).listed.ids == @["s", "t"]
    check rc.modules(module = someText("slow_module"), instance = someText("s")).listed.ids ==
      @["s"]
    let none =
      rc.modules(module = someText("meter_module"), instance = someText("s")).listed
    check none.modules.len == 0 and none.next_cursor.isNone
    check rc.modules(instance = someText("nobody")).listed.modules.len == 0
    e.finish()

  test "[RUN-0954] [RUN-0955] [RUN-0875] the limit is 100 when absent and from 1 through 1000 when present":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    for i in 0 ..< 150:
      discard e.create(slow(), "x" & align($i, 3, '0')).tryGet
    let f = someText("slow_module")
    let first = rc.modules(module = f).listed
    check first.modules.len == 100 and first.next_cursor.isSome
    let rest = rc.modules(module = f, cursor = first.next_cursor).listed
    check rest.modules.len == 50 and rest.next_cursor.isNone
    check (first.ids & rest.ids) == toSeq(0 ..< 150).mapIt("x" & align($it, 3, '0'))
    for n in [0, 1001, 65535]:
      let r = rc.modules(limit = some16(n))
      check r.code == ecInvalidParams
      check r.detail.len == 0
    check rc.modules(module = f, limit = some16(1000)).listed.modules.len == 150
    check rc.modules(module = f, limit = some16(1)).listed.modules.len == 1
    e.finish()

  test "[RUN-0956] [RUN-0957] [RUN-0961] [RUN-0361] [RUN-0362] [RUN-0972] [RUN-0976] pages come from one snapshot in a fixed order, with a cursor exactly while more remain":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    e.slows("a1", "a2", "a3", "a4", "a5")
    let f = someText("slow_module")
    let p1 = rc.modules(module = f, limit = some16(2)).listed
    check p1.ids == @["a1", "a2"] and p1.next_cursor.isSome
    # Changes after the snapshot neither appear nor reorder it: a new instance
    # that sorts first, and a state change.
    e.slows("a0")
    check e.start("a3").tryGet.state == msReady
    let p2 = rc.modules(module = f, limit = some16(2), cursor = p1.next_cursor).listed
    check p2.ids == @["a3", "a4"] and p2.next_cursor.isSome
    check p2.modules[0].state.kind == LogosNSRuntimeControlStateKind.Unloaded
    let p3 = rc.modules(module = f, limit = some16(2), cursor = p2.next_cursor).listed
    check p3.ids == @["a5"] and p3.next_cursor.isNone
    # A retried cursor returns the same page and the same continuation.
    let again =
      rc.modules(module = f, limit = some16(2), cursor = p1.next_cursor).listed
    check again.ids == p2.ids and again.next_cursor == p2.next_cursor
    # A new query reads the current inventory.
    let now = rc.modules(module = f).listed
    check now.ids == @["a0", "a1", "a2", "a3", "a4", "a5"]
    check now.modules[3].state.kind == LogosNSRuntimeControlStateKind.Ready
    e.finish()

  test "[RUN-0347] [RUN-0960] [RUN-0961] [RUN-0963] a cursor answers its own query only; any other is INVALID_PARAMS with one message and no detail":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    let (_, other) = e.startClient("d")
    e.slows("a1", "a2", "a3")
    let f = someText("slow_module")
    let c = rc.modules(module = f, limit = some16(1)).listed.next_cursor
    check c.isSome
    let bare = rc.modules(limit = some16(1)).listed.next_cursor
    check bare.isSome
    var refused: seq[RcResult]
    refused.add(rc.modules(module = f, limit = some16(2), cursor = c)) # the limit
    refused.add(rc.modules(module = f, cursor = c)) # the default limit
    refused.add(rc.modules(limit = some16(1), cursor = c)) # a filter dropped
    refused.add(
      rc.modules(module = f, instance = someText("a2"), limit = some16(1), cursor = c)
    )
    refused.add(
      rc.modules(module = someText("meter_module"), limit = some16(1), cursor = c)
    )
    refused.add(other.modules(module = f, limit = some16(1), cursor = c)) # the consumer
    refused.add(rc.routeList(limit = some16(1), cursor = bare)) # the method
    refused.add(rc.modules(module = f, limit = some16(1), cursor = someText("unknown")))
    for r in refused:
      check r.code == ecInvalidParams
      check r.detail.len == 0
      check r.message == refused[0].message
    # The cursor still answers its own query.
    check rc.modules(module = f, limit = some16(1), cursor = c).listed.ids == @["a2"]
    check rc.modules(limit = some16(1), cursor = bare).listed.modules.len == 1
    e.finish()

  test "[RUN-0963] [RUN-0965] [RUN-0970] an expired cursor is refused as an unknown one":
    for idle in [true, false]:
      var cfg = config()
      if idle:
        cfg.limits.snapshotIdle = initDuration(milliseconds = 50)
      else:
        cfg.limits.snapshotLifetime = initDuration(milliseconds = 50)
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      e.slows("a1", "a2")
      let c = rc.modules(module = someText("slow_module"), limit = some16(1)).listed.next_cursor
      check c.isSome
      sleep(120)
      let r =
        rc.modules(module = someText("slow_module"), limit = some16(1), cursor = c)
      check r.code == ecInvalidParams
      check r.detail.len == 0
      e.finish()

  test "[RUN-0966] [RUN-0967] [RUN-0968] a consumer past its allowance loses its own least recently used snapshot, never another's":
    var cfg = config()
    cfg.limits.snapshotsPerConsumer = 2
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    let (_, other) = e.startClient("d")
    e.slows("a1", "a2", "a3")
    let f = someText("slow_module")
    let one = some16(1)
    let theirs = other.modules(module = f, limit = one).listed.next_cursor
    let c1 = rc.modules(module = f, limit = one).listed.next_cursor
    let c2 = rc.modules(module = f, limit = one).listed.next_cursor
    # c1 is used again: c2's snapshot is now the least recently used.
    check rc.modules(module = f, limit = one, cursor = c1).listed.ids == @["a2"]
    let c3 = rc.modules(module = f, limit = one).listed.next_cursor
    check rc.modules(module = f, limit = one, cursor = c2).code == ecInvalidParams
    check rc.modules(module = f, limit = one, cursor = c1).listed.ids == @["a2"]
    check rc.modules(module = f, limit = one, cursor = c3).listed.ids == @["a2"]
    check other.modules(module = f, limit = one, cursor = theirs).listed.ids == @["a2"]
    # By bytes as well: one snapshot fits the allowance, a second evicts it.
    var small = config()
    let probe = fixtureEngine(small)
    let (_, prc) = probe.startClient("c")
    probe.slows("a1", "a2", "a3")
    let size = encode(
      prc.modules(module = f, instance = someText("a1")).listed.modules[0]
    ).tryGet.len
    probe.finish()
    var bytes = config()
    bytes.limits.snapshotBytesPerConsumer = 5 * size
    let b = fixtureEngine(bytes)
    let (_, brc) = b.startClient("c")
    b.slows("a1", "a2", "a3")
    let b1 = brc.modules(module = f, limit = one).listed.next_cursor
    let b2 = brc.modules(module = f, limit = one).listed.next_cursor
    check brc.modules(module = f, limit = one, cursor = b1).code == ecInvalidParams
    check brc.modules(module = f, limit = one, cursor = b2).listed.ids == @["a2"]
    b.finish()
    e.finish()

  test "[RUN-0966] [RUN-0968] [RUN-0970] [RUN-0971] past the aggregate limit a first page that would continue is MODULE_ERROR, and no other cursor is lost":
    var cfg = config()
    cfg.limits.snapshotsTotal = 1
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    let (_, other) = e.startClient("d")
    e.slows("a1", "a2", "a3")
    let f = someText("slow_module")
    let theirs = other.modules(module = f, limit = some16(1)).listed.next_cursor
    check theirs.isSome
    let r = rc.modules(module = f, limit = some16(1))
    check r.code == ecModule
    check r.response.len == 0
    # A page that needs no continuation retains nothing and is answered.
    let whole = rc.modules(module = f).listed
    check whole.ids == @["a1", "a2", "a3"] and whole.next_cursor.isNone
    check other.modules(module = f, limit = some16(1), cursor = theirs).listed.ids ==
      @["a2"]
    e.finish()

  test "[RUN-0966] [RUN-0967] a consumer's snapshots are reclaimed when its attempt ends":
    var cfg = config()
    cfg.limits.snapshotsTotal = 1
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    let (_, other) = e.startClient("d")
    e.slows("a1", "a2")
    let f = someText("slow_module")
    let c = rc.modules(module = f, limit = some16(1)).listed.next_cursor
    check c.isSome
    check other.modules(module = f, limit = some16(1)).code == ecModule
    check e.stop("c").tryGet.state == msUnloaded
    check other.modules(module = f, limit = some16(1)).listed.next_cursor.isSome
    check e.start("c").tryGet.state == msReady
    let again = latestClient()
    check again.modules(module = f, limit = some16(1), cursor = c).code ==
      ecInvalidParams
    e.finish()

  test "[RUN-0956] [RUN-0958] [RUN-0959] a page holds fewer records to fit the response size; a record that cannot fit is MODULE_ERROR":
    let f = someText("slow_module")
    let probe = fixtureEngine(config())
    let (_, prc) = probe.startClient("c")
    probe.slows("a1")
    let size = encode(prc.modules(module = f).listed.modules[0]).tryGet.len
    probe.finish()
    var cfg = config()
    cfg.limits.listResponseBytes = 2 * size + size div 2
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    e.slows("a1", "a2", "a3", "a4", "a5")
    var pages: seq[seq[string]]
    var cursor = Opt.none(string)
    while true:
      let p = rc.modules(module = f, cursor = cursor).listed
      pages.add(p.ids)
      if p.next_cursor.isNone or pages.len > 5:
        break
      cursor = p.next_cursor
    check pages == @[@["a1", "a2"], @["a3", "a4"], @["a5"]]
    var tiny = config()
    tiny.limits.listResponseBytes = size - 1
    let t = fixtureEngine(tiny)
    let (_, trc) = t.startClient("c")
    t.slows("a1")
    let r = trc.modules(module = f)
    check r.code == ecModule
    check r.response.len == 0
    t.finish()
    e.finish()

  test "[IMPL-DECISION G161] [RUN-0850] [RUN-0950] [RUN-0951] [RUN-0957] [RUN-0964] [RUN-0974] a record the caller may not observe is omitted, and counts toward no page or continuation":
    let e = fixtureEngine(
      config(
        denying(
          deny(action = Opt.some(aaObserve), operation = "list_modules", target = "a2"),
          deny(action = Opt.some(aaObserve), operation = "list_modules", target = "a5"),
          deny(action = Opt.some(aaObserve), operation = "list_modules", target = "m"),
        )
      )
    )
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    e.slows("a1", "a2", "a3", "a4", "a5")
    let f = someText("slow_module")
    let p1 = rc.modules(module = f, limit = some16(2)).listed
    check p1.ids == @["a1", "a3"] and p1.next_cursor.isSome
    let p2 = rc.modules(module = f, limit = some16(2), cursor = p1.next_cursor).listed
    check p2.ids == @["a4"] and p2.next_cursor.isNone
    # A filter grants nothing.
    check rc.modules(module = someText("meter_module")).listed.modules.len == 0
    check rc.modules(instance = someText("a2")).listed.modules.len == 0
    e.finish()

  test "[RUN-0346] [RUN-0850] [RUN-0874] [IMPL-DECISION G171] a refused list method is NOT_AUTHORISED before its payload is judged":
    let e = fixtureEngine(
      config(
        denying(
          deny(action = Opt.some(aaObserve), operation = "list_modules"),
          deny(action = Opt.some(aaObserve), operation = "list_routes"),
        )
      )
    )
    let (_, rc) = e.startClient("c")
    e.slows("a1")
    check rc.modules().code == ecNotAuthorised
    check rc.modules(limit = some16(0)).code == ecNotAuthorised
    check rc.modules(cursor = someText("unknown")).code == ecNotAuthorised
    check rcCall(rc, "list_modules", [0xA1'u8, 0x61, 0x7A, 0x01]).code == ecNotAuthorised
    check rc.routeList(limit = some16(0)).code == ecNotAuthorised
    e.finish()

  test "[RUN-0870] [RUN-0871] [RUN-0872] [RUN-0873] [RUN-0952] [RUN-1052] [RUN-1057] [RUN-1060] a failure carries its classification; a Loader message is never disclosed, other text is cut at 512 bytes":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    var missing = ModuleRecord(module: "gated_consumer", strategy: stDirectDynamic)
    missing.artifact = ArtifactRecord(
      id: "a", localPath: work / "missing" & LibraryExtension, hashSuite: HashSuiteId
    )
    discard e.create(missing, "x").tryGet
    check e.start("x").tryGet.state == msError
    let x = rc.modules(instance = someText("x")).listed.modules
    check x.len == 1
    check x[0].state.kind == LogosNSRuntimeControlStateKind.Error
    check x[0].failure == Opt.some("loader-artifact-unavailable")
    check x[0].reason.isNone
    # A reported failure's own text, cut at a character boundary.
    let text = "é".repeat(300) # 600 bytes
    check e.reportFailure("m", e.view("m").tryGet.attempt, text).isOk
    check waitUntil(
      proc(): bool =
        e.view("m").tryGet.state == msError
    )
    let m = rc.modules(instance = someText("m")).listed.modules[0]
    check m.failure.isSome
    check m.reason.get.len == 512 and m.reason.get == text[0 ..< 512]
    # A ready instance carries no failure.
    let c = rc.modules(instance = someText("c")).listed.modules[0]
    check c.failure.isNone and c.reason.isNone
    e.finish()

# list_routes --------------------------------------------------------------------------

suite "run.rc: list_routes (RUNTIME §9.3 l.3359-3365, l.3372-3413)":
  test "[RUN-0406] [RUN-0416] [RUN-0417] [RUN-0545] [RUN-0612] every route record by route id, ended ones included, without invocation":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    let rt = e.runtimeInstanceId
    var ids: seq[string]
    for k in ["k1", "k2", "k3"]:
      ids.add(rc.routeId(k))
    check rc.close(ids[1]).code == ecOk
    let got = rc.routeList().routesListed
    check got.next_cursor.isNone
    check got.routes.mapIt(it.route) == e.routes().mapIt(it.route).sorted()
    for r in got.routes:
      check r.invocation.isNone
      check r.consumer == e.address("c")
      check r.target_provider.runtime_instance_id == Opt.some(rt)
      check r.module == "meter_module"
      check r.instance == Opt.some("m")
    let closed = got.routes.filterIt(it.route == ids[1])
    check closed.len == 1
    check closed[0].state.kind == LogosNSRuntimeControlRouteStateKind.Closed
    e.finish()

  test "[RUN-0960] [RUN-0961] the module and provider filters match; a provider without a Runtime id names this Runtime, another Runtime's matches nothing":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m1")
    discard e.started(meter(), "m2")
    let (_, rc) = e.startClient("c")
    let rt = e.runtimeInstanceId
    let p1 = e.view("m1").tryGet.providerId
    let p2 = e.view("m2").tryGet.providerId
    var to1, to2: seq[string]
    for k in ["a", "b"]:
      let r = rc.establish(k, provider = Opt.some(providerAddress(p1)))
      check r.code == ecOk
      to1.add(r.routesOf.routes[0].route)
    let r2 = rc.establish("c", provider = Opt.some(providerAddress(p2)))
    check r2.code == ecOk
    to2.add(r2.routesOf.routes[0].route)
    let bare = Opt.some(providerAddress(p1))
    let local = Opt.some(providerAddress(p1, Opt.some(rt)))
    check rc.routeList(provider = bare).routesListed.routes.mapIt(it.route) ==
      to1.sorted()
    check rc.routeList(provider = local).routesListed.routes.mapIt(it.route) ==
      to1.sorted()
    check rc
      .routeList(provider = Opt.some(providerAddress(p2))).routesListed.routes
      .mapIt(it.route) == to2
    let foreign =
      rc.routeList(provider = Opt.some(providerAddress(p1, Opt.some(ForeignRuntime))))
    check foreign.routesListed.routes.len == 0
    check rc.routeList(module = someText("meter_module")).routesListed.routes.len == 3
    check rc.routeList(module = someText("slow_module")).routesListed.routes.len == 0
    # A cursor is bound to the normalized filter: either spelling continues it.
    let first = rc.routeList(provider = bare, limit = some16(1)).routesListed
    check first.next_cursor.isSome
    let next = rc.routeList(
      provider = local, limit = some16(1), cursor = first.next_cursor
    ).routesListed
    check (first.routes & next.routes).mapIt(it.route) == to1.sorted()
    check next.next_cursor.isNone
    e.finish()

  test "[RUN-0950] [RUN-0951] [IMPL-DECISION G161] [IMPL-DECISION G226] a route the caller may not observe is omitted":
    let e = fixtureEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaObserve),
            operation = "list_routes",
            module = "meter_module",
          )
        )
      )
    )
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    discard rc.routeId("k")
    let got = rc.routeList().routesListed
    check got.routes.len == 0 and got.next_cursor.isNone
    # The module list is another method: still visible.
    check rc.modules(instance = someText("m")).listed.ids == @["m"]
    e.finish()

# get_execution_summary ----------------------------------------------------------------

suite "run.rc: get_execution_summary (RUNTIME §9.3 l.3513-3535)":
  test "[RUN-0441] [RUN-0442] [RUN-0440] [RUN-0634] [RUN-0636] [RUN-0637] [RUN-0639] [RUN-0642] [RUN-0994] a ready instance: one committed view, a current realization, its strategy as the selection":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    let s = rc.summaryOf(e.address("m")).summarized
    let v = e.view("m").tryGet
    check s.target == e.address("m")
    check s.state.kind == LogosNSRuntimeControlStateKind.Ready
    check s.execution.revision == v.execution.revision
    check s.failure.isNone
    check s.realization.kind ==
      LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Current
    check s.selection.isSome
    check s.selection.get.implementation.kind ==
      LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Direct_static
    check s.selection.get.package.isNone and s.selection.get.signer.isNone
    # [I89; G57] The Module Loader itself, realized by the bootstrap mechanism.
    let l = rc.summaryOf(e.address(LoaderInstanceId)).summarized
    check l.selection.get.implementation.kind ==
      LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Implementation_specific
    e.finish()

  test "[RUN-0640] [RUN-0641] [RUN-1057] no realization before a start, after a failed bind and after a stop":
    let e = fixtureEngine(config())
    discard e.create(meter(), "m").tryGet
    let (_, rc) = e.startClient("c")
    const Absent =
      LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Absent
    check rc.realizationOf(e, "m") == Absent
    check e.start("m").tryGet.state == msReady
    check e.stop("m").tryGet.state == msUnloaded
    check rc.realizationOf(e, "m") == Absent
    var missing = ModuleRecord(module: "gated_consumer", strategy: stDirectDynamic)
    missing.artifact = ArtifactRecord(
      id: "a", localPath: work / "missing" & LibraryExtension, hashSuite: HashSuiteId
    )
    discard e.create(missing, "x").tryGet
    check e.start("x").tryGet.state == msError
    let x = rc.summaryOf(e.address("x")).summarized
    check x.state.kind == LogosNSRuntimeControlStateKind.Error
    check x.failure == Opt.some("loader-artifact-unavailable")
    check x.realization.kind == Absent
    check x.selection.get.implementation.kind ==
      LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Direct_dynamic
    e.finish()

  test "[RUN-0634] [RUN-0635] [RUN-0875] [IMPL-DECISION G228] a target on another Runtime is INVALID_PARAMS without detail; an unknown or refused target is NOT_AUTHORISED":
    let e = fixtureEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaObserve),
            operation = "get_execution_summary",
            target = "s",
          )
        )
      )
    )
    discard e.started(meter(), "m")
    e.slows("s")
    let (_, rc) = e.startClient("c")
    let foreign = rc.summaryOf(e.address("m", ForeignRuntime))
    check foreign.code == ecInvalidParams
    check foreign.detail.len == 0
    let unknown = rc.summaryOf(e.address("nobody"))
    let refused = rc.summaryOf(e.address("s"))
    check unknown.code == ecNotAuthorised and refused.code == ecNotAuthorised
    check unknown.detail.len == 0 and refused.detail.len == 0
    check rc.summaryOf(e.address("m")).code == ecOk
    e.finish()

  test "[RUN-0640] [RUN-0630] [IMPL-DECISION G180] [IMPL-DECISION G227] a cleanup past its deadline is unknown; its end is absent at a new revision, and a revision read before it is stale":
    let e = fixtureEngine(config())
    let (_, rc) = e.startClient("c")
    discard e.started(client(), "w")
    clientDestroyGate.store(true)
    let stopped = e.stop("w").tryGet
    check stopped.state == msError
    check stopped.failure.get.classification == "cleanup-timeout"
    const Unknown =
      LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Unknown
    const Absent =
      LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Absent
    let during = rc.summaryOf(e.address("w")).summarized
    check during.realization.kind == Unknown
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        rc.realizationOf(e, "w") == Absent,
      10 * Slow,
    )
    let after = rc.summaryOf(e.address("w")).summarized
    check after.execution.revision > during.execution.revision
    check after.state.kind == LogosNSRuntimeControlStateKind.Error
    # A guarded request prepared before the commit is refused, without
    # mutation; one at the current revision is accepted.
    let stale = rc.lifecycle(
      "start_module",
      "client_module",
      instance = someText("w"),
      expected = Opt.some(during.execution.revision),
    )
    check stale.code == ecInvalidParams
    check e.view("w").tryGet.execution.revision == after.execution.revision
    let fresh = rc.lifecycle(
      "start_module",
      "client_module",
      instance = someText("w"),
      expected = Opt.some(after.execution.revision),
    )
    check fresh.code == ecOk
    check e.view("w").tryGet.state == msReady
    e.finish()

  test "[RUN-0640] [IMPL-DECISION G227] a reported failure keeps the realization current while it is released, then absent at a new revision":
    var cfg = config()
    cfg.stopDeadline = initDuration(seconds = 10 * Slow) # the release stays in time
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    discard e.started(client(), "w")
    clientDestroyGate.store(true)
    check e.reportFailure("w", e.view("w").tryGet.attempt, "gone").isOk
    check waitUntil(
      proc(): bool =
        e.view("w").tryGet.state == msError
    )
    const Current =
      LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Current
    const Absent =
      LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Absent
    let during = rc.summaryOf(e.address("w")).summarized
    check during.realization.kind == Current
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        rc.realizationOf(e, "w") == Absent,
      10 * Slow,
    )
    let after = rc.summaryOf(e.address("w")).summarized
    check after.execution.revision > during.execution.revision
    check after.failure == during.failure
    e.finish()

# describe_provider --------------------------------------------------------------------

suite "run.rc: describe_provider (RUNTIME §2.4 l.448-458)":
  test "[RUN-0094] [RUN-0095] [RUN-0412] [RUN-0413] [CAP-0042] the exact call surface validated at the provider's bind, after a stop too":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    let rt = e.runtimeInstanceId
    let p = e.view("m").tryGet.providerId
    let want = meterSurface()
    check want.len > 0
    for address in [providerAddress(p), providerAddress(p, Opt.some(rt))]:
      let r = rc.describeOf(address)
      check r.code == ecOk
      let d = LogosNSRuntimeControlDescribeProviderResponse.decode(r.response).tryGet
      check d.provider == providerAddress(p, Opt.some(rt))
      check d.surface == want
      check acceptCallSurfaceDescriptor(d.surface, "meter_module").tryGet.primary.get.root ==
        meterRoot
    # [SPEC RUNTIME l.540-541] Retained after the realization ends.
    check e.stop("m").tryGet.state == msUnloaded
    let after = rc.describeOf(providerAddress(p))
    check after.code == ecOk
    check LogosNSRuntimeControlDescribeProviderResponse.decode(after.response).tryGet.surface ==
      want
    e.finish()

  test "[RUN-0091] [RUN-0093] [CAP-0042] [CAP-0043] [CAP-0156] [IFC-0471] another Runtime is INVALID_PARAMS; an unknown or refused provider and a refused discover are NOT_AUTHORISED; never bound is NOT_READY":
    block:
      let e = fixtureEngine(config())
      discard e.started(meter(), "m")
      discard e.create(meter(), "n").tryGet
      let (_, rc) = e.startClient("c")
      let p = e.view("m").tryGet.providerId
      let foreign = rc.describeOf(providerAddress(p, Opt.some(ForeignRuntime)))
      check foreign.code == ecInvalidParams
      check foreign.detail.len == 0
      let unknown = rc.describeOf(providerAddress("p-nobody"))
      check unknown.code == ecNotAuthorised and unknown.detail.len == 0
      # [SPEC RUNTIME l.660] Never bound: NOT_READY, after every decision.
      check rc.describeOf(providerAddress(e.view("n").tryGet.providerId)).code ==
        ecNotReady
      e.finish()
    block:
      let e = fixtureEngine(
        config(
          denying(
            deny(
              action = Opt.some(aaObserve),
              operation = "describe_provider",
              module = "meter_module",
            )
          )
        )
      )
      discard e.started(meter(), "m")
      let (_, rc) = e.startClient("c")
      let r = rc.describeOf(providerAddress(e.view("m").tryGet.providerId))
      check r.code == ecNotAuthorised and r.detail.len == 0
      e.finish()
    block:
      # [D5] The discover decisions come before readiness: a caller refused
      # them never learns whether the provider was bound.
      let e = fixtureEngine(config(denying(deny(action = Opt.some(aaDiscover)))))
      discard e.started(meter(), "m")
      discard e.create(meter(), "n").tryGet
      let (_, rc) = e.startClient("c")
      let bound = rc.describeOf(providerAddress(e.view("m").tryGet.providerId))
      let never = rc.describeOf(providerAddress(e.view("n").tryGet.providerId))
      check bound.code == ecNotAuthorised and never.code == ecNotAuthorised
      check bound.message == never.message
      e.finish()

  test "[RUN-0096] [RUN-0413] a surface of the largest size fits the response Runtime Control validates and returns":
    # [IMPL] The direct path (`invoke.rcInvoke`) checks a response against its
    # schema and commits it, and imposes no size bound of its own; no transport
    # carries Runtime Control in Tier 4 (G48).
    const declaration = "logos.runtime_control.describe_provider_response"
    var big = LogosNSRuntimeControlDescribeProviderResponse(
      provider: providerAddress("p-1", Opt.some(ForeignRuntime)),
      surface: newSeq[byte](MaxDescriptorBytes),
    )
    let bytes = encode(big).tryGet
    check bytes.len > MaxDescriptorBytes
    let v = rcSchema().decodeChecked(declaration, bytes)
    check v.isOk
    if v.isOk:
      check rcSchema().commitment(declaration, v.get).isOk
    big.surface.add(0)
    let over = encode(big)
    check over.isErr or rcSchema().decodeChecked(declaration, over.get).isErr

# Permission settings ------------------------------------------------------------------

suite "run.rc: permission settings in direct mode (RUNTIME l.2526-2604) [IMPL-DECISION G229]":
  test "[RUN-0893] [RUN-0910] [RUN-0469] [RUN-0471] every local instance has its settings at revision 1, empty and applied":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    e.slows("s")
    let (_, rc) = e.startClient("c")
    for target in ["m", "s", "c"]:
      let r = rc.settingsOf(e.address(target))
      check r.code == ecOk
      let s =
        LogosNSRuntimeControlGetPermissionSettingsResponse.decode(r.response).tryGet
      check s.target == e.address(target)
      check s.state.revision == 1
      check s.state.permissions.len == 0
      check s.state.failure.isNone
      check s.state.application.kind ==
        LogosNSRuntimeControlPermissionSettingsStateApplicationChoiceKind.Applied
    e.finish()

  test "[RUN-0468] [RUN-0470] [RUN-0474] [RUN-0475] [RUN-0481] [RUN-0892] [RUN-0875] an empty replacement at revision 1 returns that state; a permission or another revision is INVALID_PARAMS without detail":
    let e = fixtureEngine(config())
    discard e.started(meter(), "m")
    let (_, rc) = e.startClient("c")
    let before = e.view("m").tryGet
    let same = rc.updateOf(e.address("m"), 1)
    check same.code == ecOk
    let s =
      LogosNSRuntimeControlUpdatePermissionSettingsResponse.decode(same.response).tryGet
    check s.target == e.address("m")
    check s.state.revision == 1 and s.state.permissions.len == 0
    check s.state.application.kind ==
      LogosNSRuntimeControlPermissionSettingsStateApplicationChoiceKind.Applied
    let named = rc.updateOf(
      e.address("m"),
      1,
      @[
        LogosNSRuntimeControlPermissionSetting(permission: "p", constraints: @[0xF6'u8])
      ],
    )
    check named.code == ecInvalidParams and named.detail.len == 0
    for revision in [0'u64, 2]:
      let stale = rc.updateOf(e.address("m"), revision)
      check stale.code == ecInvalidParams and stale.detail.len == 0
    # Nothing changed, the instance included.
    let after = e.view("m").tryGet
    check after.execution.revision == before.execution.revision
    check after.state == msReady
    let again = rc.settingsOf(e.address("m"))
    check LogosNSRuntimeControlGetPermissionSettingsResponse.decode(again.response).tryGet.state.revision ==
      1
    e.finish()

  test "[RUN-0473] [RUN-0910] [RUN-0875] [IMPL-DECISION G228] each method is authorized apart, for a local target":
    let e = fixtureEngine(
      config(
        denying(
          deny(
            action = Opt.some(aaLifecycle),
            operation = "update_permission_settings",
            target = "m",
          ),
          deny(
            action = Opt.some(aaObserve),
            operation = "get_permission_settings",
            target = "s",
          ),
        )
      )
    )
    discard e.started(meter(), "m")
    e.slows("s")
    let (_, rc) = e.startClient("c")
    check rc.settingsOf(e.address("m")).code == ecOk
    check rc.updateOf(e.address("m"), 1).code == ecNotAuthorised
    check rc.settingsOf(e.address("s")).code == ecNotAuthorised
    check rc.updateOf(e.address("s"), 1).code == ecOk
    # The refusal comes before the payload is judged.
    check rc.updateOf(e.address("m"), 7).code == ecNotAuthorised
    for r in [
      rc.settingsOf(e.address("m", ForeignRuntime)),
      rc.updateOf(e.address("m", ForeignRuntime), 1),
    ]:
      check r.code == ecInvalidParams and r.detail.len == 0
    check rc.settingsOf(e.address("nobody")).code == ecNotAuthorised
    check rc.updateOf(e.address("nobody"), 1).code == ecNotAuthorised
    e.finish()

# The Capability Authority's narrowing ---------------------------------------------------

when declared(caParity):
  proc narrowing(what: string, alternatives: varargs[RcNarrow]): Rule =
    Rule(what: what, verdict: vAllow, validMs: Everything, narrowControl: @alternatives)

  proc changePolicy(revision: uint64) =
    ## A new script takes effect: the cached decisions go.
    check publish(PolicyChangedName, policyChanged(revision - 1, revision))

  func only(s: varargs[string]): Opt[seq[string]] =
    Opt.some(@s)

  suite "run.rc: observation under a narrowed allow (CA l.306-308, l.554-567) [IMPL-DECISION G161] [IMPL-DECISION G226]":
    test "[RUN-0950] [RUN-0951] [CAP-0055] [CAP-0115] [CAP-0116] [CAP-0117] a record is shown only when one alternative admits it whole":
      let e = fixtureEngine(config())
      let (_, rc) = e.startClient("c")
      e.slows("a1", "a2")
      discard e.create(meter(), "b1").tryGet
      discard e.create(meter(), "b2").tryGet
      setScript(narrowing("rc:list_modules", RcNarrow(modules: only("slow_module"))))
      check rc.modules().listed.ids == @["a1", "a2"]
      setScript(
        narrowing(
          "rc:list_modules",
          RcNarrow(modules: only("slow_module")),
          RcNarrow(instances: only("b1")),
        )
      )
      changePolicy(1)
      check rc.modules().listed.ids == @["a1", "a2", "b1"]
      # Selectors of different alternatives are never combined.
      setScript(
        narrowing(
          "rc:list_modules",
          RcNarrow(modules: only("slow_module"), instances: only("b1")),
          RcNarrow(modules: only("meter_module"), instances: only("a1")),
        )
      )
      changePolicy(2)
      check rc.modules().listed.modules.len == 0
      # [G226] A `providers` selector matches only a record exposing a
      # provider.
      let p1 = e.view("b1").tryGet.providerId
      setScript(narrowing("rc:list_modules", RcNarrow(providers: only(p1))))
      changePolicy(3)
      check rc.modules().listed.ids == @["b1"]
      e.finish()

    test "[RUN-0962] [RUN-0964] [RUN-0969] each page applies the current decision to the facts kept with its records, after a retirement too":
      let e = fixtureEngine(config())
      let (_, rc) = e.startClient("c")
      e.slows("a1", "a2", "a3")
      let f = someText("slow_module")
      let p1 = rc.modules(module = f, limit = some16(1)).listed
      check p1.ids == @["a1"] and p1.next_cursor.isSome
      # a2 is retired after the snapshot; the narrowed decision admits it by
      # its retained facts, and hides a3, which keeps no continuation alive.
      check rc.retireOf(e, "a2").code == ecOk
      check e.view("a2").isErr
      setScript(narrowing("rc:list_modules", RcNarrow(instances: only("a1", "a2"))))
      changePolicy(1)
      let p2 = rc.modules(module = f, limit = some16(1), cursor = p1.next_cursor).listed
      check p2.ids == @["a2"] and p2.next_cursor.isNone
      e.finish()

    test "[RUN-0950] [RUN-0951] [CAP-0055] a route is matched by its own facts, never by its consumer":
      let e = fixtureEngine(config())
      discard e.started(meter(), "m1")
      discard e.started(meter(), "m2")
      let (_, rc) = e.startClient("c")
      let p1 = e.view("m1").tryGet.providerId
      let p2 = e.view("m2").tryGet.providerId
      let r1 =
        rc.establish("a", provider = Opt.some(providerAddress(p1))).routesOf.routes[0].route
      let r2 =
        rc.establish("b", provider = Opt.some(providerAddress(p2))).routesOf.routes[0].route
      setScript(narrowing("rc:list_routes", RcNarrow(routes: only(r2))))
      check rc.routeList().routesListed.routes.mapIt(it.route) == @[r2]
      setScript(narrowing("rc:list_routes", RcNarrow(providers: only(p1))))
      changePolicy(1)
      check rc.routeList().routesListed.routes.mapIt(it.route) == @[r1]
      setScript(narrowing("rc:list_routes", RcNarrow(instances: only("m2"))))
      changePolicy(2)
      check rc.routeList().routesListed.routes.mapIt(it.route) == @[r2]
      # The consumer is not a fact of the route record (S7-2).
      setScript(narrowing("rc:list_routes", RcNarrow(instances: only("c"))))
      changePolicy(3)
      check rc.routeList().routesListed.routes.len == 0
      e.finish()
