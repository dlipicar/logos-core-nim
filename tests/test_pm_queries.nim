## The Package Manager's queries (Tier 5 step 5-6b-1; DECISIONS G498, G499, G500;
## docs/PACKAGE-MANAGER.md §13): readers, cursors and their retention policy, and the two
## lists' pages. The policy's counts and ages are checked on `cursors.nim` with its clock
## given (the engine's page-job bounds are `test_pm_install`'s, on `pmworld`). What a
## reader sees is checked through the Module Host's boundary below, as `test_pm_module`
## checks the operations: `liblogos_package_manager` hosted under a test Runtime with one
## Runtime id, its protected input naming the client instances `c` and `d` as readers and
## not `x`. A reader's `get_runtime_handoff` is `test_system_binding`'s, beside the
## binding's.
##
## The Module Host inherits the test's fd 2 when it is spawned: a case that reads the
## module's operator lines points fd 2 at a file for the start (`startedLogging`).

import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times]
import unittest2
import results
import ../src/logos_core/runtime/engine
import logos_sdk/abi/[checks, types]
import ../src/logos_core/runtime/routes
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/iface/[accept, outcome, provider, surface]
import logos_sdk/codegen/common_types
import logos_sdk/pins
import logos_sdk/testing/[kitbuild, kitruntime]
import logos_sdk/testing/fixtures/[meter_impl, fetch_fake_impl]
import logos_sdk/testing/generated/meter_module_calls
import logos_sdk/contracts/generated/lcn_storage_fetch_root
import ../src/logos_core/pins as core_pins
import ../src/logos_core/package/[manifest, records]
import ../src/logos_core/pm/[cursors, linelimit, listing]
from ./support/pmfixture import textOf

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "pm-queries" / kitVariant
  cfgTypesDoc = readFile(repo / "spec/mirrors/CFG/9.configuration-types.cddl")
removeDir(work)
createDir(work)

include ./support/routefixture

# Helpers --------------------------------------------------------------------------------

proc tokenCounter(): TokenSource =
  ## Tokens 1, 2, 3, …: a case's own, so it can name them.
  var n = 0
  result = proc(): string {.gcsafe, raises: [].} =
    inc n
    "t" & $n

let
  oa = cursors.Origin(runtime: "rt", instance: "a")
  ob = cursors.Origin(runtime: "rt", instance: "b")

func commitmentOf(n: byte): ManifestCommitment =
  var c = ManifestCommitment(commitmentModel: "m", hashProfile: "p", hashSuite: "s")
  c.valueRoot[0] = n
  c

# The cursors and their retention policy (G499) ---------------------------------------------

suite "the cursors' retention policy (G499)":
  test "[PKG-0538] [PKG-0539] [PKG-0540] [IMPL-DECISION G499] an origin at 8 cursors loses its own least recently used one, never another origin's":
    var c = initCursors(tokenCounter())
    discard c.issue(ob, cmListInstalled, Opt.none(string), 1, 0, now = 0)
    for i in 1 .. PerOrigin:
      let (st, _) = c.issue(oa, cmListInstalled, Opt.none(string), 1, i, now = int64(i))
      check st == ciIssued
    check c.held(oa) == PerOrigin
    # t2 is a's oldest; using it makes t3 the least recently used.
    check c.take("t2", oa, cmListInstalled, Opt.none(string), 1, now = 100).isOk
    let (st, t) = c.issue(oa, cmListInstalled, Opt.none(string), 1, 9, now = 101)
    check st == ciIssued
    check c.held(oa) == PerOrigin
    check c.held(ob) == 1
    check c.take("t3", oa, cmListInstalled, Opt.none(string), 1, now = 102).error ==
      crUnknown
    check c.take("t2", oa, cmListInstalled, Opt.none(string), 1, now = 102).isOk
    check c.take(t, oa, cmListInstalled, Opt.none(string), 1, now = 102).isOk
    check c.take("t1", ob, cmListInstalled, Opt.none(string), 1, now = 102).isOk

  test "[PKG-0541] [IMPL-DECISION G499] with the aggregate held and none of the asking origin's to give up, nothing is issued; an origin holding some gives up its own":
    var c = initCursors(tokenCounter())
    for i in 0 ..< Aggregate:
      let o = cursors.Origin(runtime: "rt", instance: "o" & $(i div PerOrigin))
      check c.issue(o, cmListPackages, Opt.none(string), 1, i, now = 0)[0] == ciIssued
    check c.len == Aggregate
    check c.issue(oa, cmListPackages, Opt.none(string), 1, 0, now = 1)[0] == ciFull
    check c.len == Aggregate
    let o0 = cursors.Origin(runtime: "rt", instance: "o0")
    check c.issue(o0, cmListPackages, Opt.none(string), 1, 0, now = 1)[0] == ciIssued
    check c.len == Aggregate
    check c.held(o0) == PerOrigin

  test "[PKG-0387] [IMPL-DECISION G499] a cursor expires 60 s after its last use and 10 min after it was made; reclamation drops it":
    var c = initCursors(tokenCounter())
    discard c.issue(oa, cmListInstalled, Opt.none(string), 1, 0, now = 0)
    check c.take("t1", oa, cmListInstalled, Opt.none(string), 1, now = IdleMs - 1).isOk
    check c.take("t1", oa, cmListInstalled, Opt.none(string), 1, now = 2 * IdleMs - 2).isOk
    check c.take("t1", oa, cmListInstalled, Opt.none(string), 1, now = 3 * IdleMs - 2).error ==
      crExpired
    # Used every 50 s, it still ends at 10 min.
    discard c.issue(oa, cmListInstalled, Opt.none(string), 1, 0, now = 0)
    var at = 0'i64
    while at + 50_000 < LifeMs:
      at += 50_000
      check c.take("t2", oa, cmListInstalled, Opt.none(string), 1, now = at).isOk
    check c.take("t2", oa, cmListInstalled, Opt.none(string), 1, now = LifeMs).error ==
      crExpired
    discard c.issue(oa, cmListInstalled, Opt.none(string), 1, 0, now = 0)
    check c.len == 1
    c.reclaim(IdleMs, installed = 1, catalog = 1)
    check c.len == 0

  test "[PKG-0384] [PKG-0387] [IMPL-DECISION G499] a cursor is bound to its origin, method and filter, and expires once its snapshot is superseded":
    var c = initCursors(tokenCounter())
    let lib = Opt.some("lib")
    discard c.issue(oa, cmListInstalled, lib, 4, 7, now = 0)
    check c.take("t1", ob, cmListInstalled, lib, 4, now = 1).error == crOther
    check c.take("t1", oa, cmListPackages, lib, 4, now = 1).error == crOther
    check c.take("t1", oa, cmListInstalled, Opt.none(string), 4, now = 1).error ==
      crOther
    check c.take("t1", oa, cmListInstalled, Opt.some("app"), 4, now = 1).error == crOther
    check c.take("zz", oa, cmListInstalled, lib, 4, now = 1).error == crUnknown
    let r = c.take("t1", oa, cmListInstalled, lib, 4, now = 1)
    check r.isOk and r.get.position == 7
    c.spend("t1")
    check c.take("t1", oa, cmListInstalled, lib, 4, now = 1).error == crUnknown
    discard c.issue(oa, cmListInstalled, lib, 4, 7, now = 0)
    check c.take("t2", oa, cmListInstalled, lib, 5, now = 1).error == crExpired
    discard c.issue(oa, cmListInstalled, lib, 4, 7, now = 0)
    discard c.issue(oa, cmListPackages, lib, 2, 7, now = 0)
    c.reclaim(1, installed = 5, catalog = 2)
    check c.len == 1

  test "[IMPL-DECISION G499] a token is 32 random bytes in base64url without padding":
    let t = randomToken()
    check t.len == 43
    check t.allIt(it in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_'})
    check randomToken() != t

# Pages (G500) ----------------------------------------------------------------------------

suite "the lists' pages (G500)":
  test "[PKG-0381] [SPEC PM l.1640] limit: absent, 100; 1 to 1000 accepted; 0 and 1001 refused":
    check limitOf(Opt.none(uint16)) == Opt.some(100)
    check limitOf(Opt.some(1'u16)) == Opt.some(1)
    check limitOf(Opt.some(1000'u16)) == Opt.some(1000)
    check limitOf(Opt.some(0'u16)).isNone
    check limitOf(Opt.some(1001'u16)).isNone

  test "[SPEC PM l.1660] list_installed_packages' order: name bytes, descending SemVer precedence, then the commitment":
    let ids = @[
      ("lib", "1.2.0"),
      ("app", "1.0.0"),
      ("lib", "1.10.0"),
      ("lib", "1.3.0"),
      ("lib", "1.3.0-rc.1"),
    ]
    var order = ids
    order.sort(
      proc(x, y: (string, string)): int =
        installedOrder(
          PackageIdentity(package: x[0], version: x[1]),
          commitmentOf(1),
          PackageIdentity(package: y[0], version: y[1]),
          commitmentOf(1),
        )
    )
    check order ==
      @[
        ("app", "1.0.0"),
        ("lib", "1.10.0"),
        ("lib", "1.3.0"),
        ("lib", "1.3.0-rc.1"),
        ("lib", "1.2.0"),
      ]
    let i = PackageIdentity(package: "x", version: "1.0.0")
    check installedOrder(i, commitmentOf(1), i, commitmentOf(2)) < 0

  test "[PKG-0368] [PKG-0378] [IMPL-DECISION G500] a page's bytes are the encoder's {packages, ? next_cursor} around the records' encodings":
    let v1 = cborMap((cbor("k"), cbor(1'u64)))
    let v2 = cbor("two")
    let items = textOf(encodeCbor(v1)) & textOf(encodeCbor(v2))
    for next in [Opt.none(string), Opt.some("abc")]:
      var m = cborMap((cbor("packages"), CborValue(kind: ckArray, items: @[v1, v2])))
      if next.isSome:
        m.entries.add((cbor("next_cursor"), cbor(next.get)))
      check pageText(items, 2, next) == textOf(encodeCbor(m))
    check pageText("", 0, Opt.none(string)) ==
      textOf(encodeCbor(cborMap((cbor("packages"), CborValue(kind: ckArray)))))

  test "[PKG-0383] [IMPL-DECISION G500] the byte budget: a first record always fits; later ones while the page stays within it":
    check PageBudget == 256 * 1024 # one constant, the engine's and the page job's
    check fits(0, PageBudget * 4, 0)
    check fits(10, PageBudget - 10, 1)
    check not fits(11, PageBudget - 10, 1)
    check not fits(0, 2, 1, budget = 1)

# The lines a caller can repeat (G495, G501; Fable §17.3 point 3, §17.7) ------------------

suite "the operator's lines a caller can repeat, limited (G495, G501)":
  let t0 = getMonoTime()
  proc at(ms: int): MonoTime =
    t0 + initDuration(milliseconds = ms)

  test "[IMPL-DECISION G495] a refusal's line (a burst of 1) is written the first time; the same line within a minute is counted, and the first after it is written with the count; another method or cause is a kind of its own; counts left are written at the stop":
    const
      x = "package-manager: list_packages refused for x: not a reader"
      y = "package-manager: list_installed_packages refused for x: not a reader"
    var r: LineLimit
    check r.admit(x, x, 1, at(0)) == @[x]
    for i in 1 .. 4:
      check r.admit(x, x, 1, at(i * 1000)).len == 0
    check r.admit(y, y, 1, at(5000)) == @[y]
    check r.admit(x, x, 1, at(LineWindowMs - 1)).len == 0
    check r.admit(x, x, 1, at(LineWindowMs)) ==
      @[x & " (5 more like it since its last line)"]
    check r.admit(x, x, 1, at(LineWindowMs + 1)).len == 0
    check r.admit(x, x, 1, at(2 * LineWindowMs + 1)) ==
      @[x & " (1 more like it since its last line)"]
    check r.admit(x, x, 1, at(3 * LineWindowMs + 1)) == @[x]
    check r.admit(y, y, 1, at(3 * LineWindowMs + 2)) == @[y]
    check r.admit(y, y, 1, at(3 * LineWindowMs + 3)).len == 0
    check r.flush() == @[y] # the one line held, no other
    check r.kinds == 0

  test "[IMPL-DECISION G501] a reader's line of one kind (a burst of 8): eight a window, the rest counted, and the first after the window written with the count; the count names the last line held":
    const head = "package-manager: watch_installed_packages admitted for c"
    var r: LineLimit
    for i in 1 .. 8:
      check r.admit(head, head & ": " & $i, 8, at(i)) == @[head & ": " & $i]
    for i in 9 .. 12:
      check r.admit(head, head & ": " & $i, 8, at(i)).len == 0
    check r.kinds == 1 # the figures a line carries are not in its kind
    check r.admit(head, head & ": 13", 8, at(LineWindowMs + 1)) ==
      @[head & ": 13 (4 more like it since its last line)"]
    check r.admit(head, head & ": 14", 8, at(LineWindowMs + 2)) == @[head & ": 14"]
    check r.flush().len == 0
    # At the stop: the last line held, with the number of the others.
    for i in 15 .. 22:
      discard r.admit(head, head & ": " & $i, 8, at(LineWindowMs + i))
    check r.admit(head, head & ": 23", 8, at(LineWindowMs + 23)).len == 0
    check r.admit(head, head & ": 24", 8, at(LineWindowMs + 24)).len == 0
    check r.flush() == @[head & ": 24 (1 more like it since its last line)"]

  test "[IMPL-DECISION G495] the kinds held are bounded: at the bound, kinds past their window are given up, each with its count; when none is, a new kind's line is counted into one overflow kind, itself a line a window, given up by the next sweep with its count":
    var r: LineLimit
    for i in 0 ..< LineKinds:
      check r.admit("k" & $i, "k" & $i, 1, t0).len == 1
    check r.admit("k0", "k0 again", 1, t0).len == 0
    check r.kinds == LineKinds
    # None past its window: a new kind goes to the overflow kind, never into the table.
    check r.admit("new0", "new0", 1, at(1)) == @[OverflowLine]
    for i in 1 .. 5:
      check r.admit("new" & $i, "new" & $i, 1, at(1 + i)).len == 0
    check r.kinds == LineKinds
    check r.admit("new6", "new6", 1, at(LineWindowMs + 1)) ==
      @["k0 again", OverflowLine & " (4 more like it since its last line)", "new6"]
    check r.kinds == 1
    check r.flush().len == 0

  test "[IMPL-DECISION G495] full with nothing due: new kinds without end leave the table at its bound and write one overflow line a window; the sweep for kinds past their window runs at most once a window, so kinds that come due between sweeps wait for the next":
    var r: LineLimit
    for i in 0 ..< LineKinds:
      discard r.admit("k" & $i, "k" & $i, 1, t0)
    var written = 0
    for i in 0 ..< 4 * LineKinds:
      written += r.admit("n" & $i, "n" & $i, 1, at(1 + i)).len
      check r.kinds == LineKinds
    check written == 1
    # Every kind is past its window at LineWindowMs, but the last sweep was at 1 ms: the
    # new kind is counted into the overflow kind (its window, from 1 ms, not passed).
    check r.admit("late", "late", 1, at(LineWindowMs)).len == 0
    check r.kinds == LineKinds
    # A window after that sweep: the next gives every kind up (none held a count) and the
    # overflow kind with its count, and the new kind is held.
    check r.admit("later", "later", 1, at(LineWindowMs + 1)) ==
      @[
        OverflowLine & " (" & $(4 * LineKinds - 1) & " more like it since its last line)",
        "later",
      ]
    check r.kinds == 1

# The queries through the Module Host's boundary ------------------------------------------

# [DECISIONS G107] The hosted cases are POSIX only, as `test_pm_module`'s: a Module Host is
# reached over the local transport, which fails closed on Windows until step 5-9.
when defined(posix):
  import logos_sdk/crypto/blake3
  import std/posix except Time
  import
    ./support/[lgxbuild, modulehostbuild, pmbuild, pmfixture, sanitizerenv, shortdir]
  import ../src/logos_core/pm/input_types
  import ./support/trnowner except Provider, now, binding, issue, live, release, gate
  from logos_sdk/testing/generated/fetch_fake_module_calls import
    invoke, FetchFakeSetReadinessRequest, FetchFakeSetReadinessRequestReadinessChoice,
    FetchFakeSetReadinessRequestReadinessChoiceKind

  const
    Answer = 60 * Slow ## seconds: bounds a wait for the Package Manager
    Wait = 1000 * Answer ## ms
    PmModule = "logos_package_manager"
    RuntimeId = "3b7c1e94-6a2d-4f05-9c81-d2e4a7b05f36"
      ## the test Runtime's id, which the protected input names (G498)
    PaceMs = 2000 * Slow
      ## the page jobs' pause per record (`LCN_TEST_PM_PAGE_PACE_MS`, `pm/jobs.nim`) where
      ## a case holds page jobs in flight
    RecordKeys = [
      "artifacts", "identity", "manifest_commitment", "modules",
      "resolved_dependencies", "signer", "source", "variant",
    ]

  let
    hostProgram = moduleHostProgram()
    fakeLib = buildKitLibrary("fetch_fake_impl.nim", "pmqfake")
    pmLib = pmLibrary()
    shortBase = makeShortBase("lcnpmq", "/e999/12345678/logos_fetch_fake_module.sock")
    contractDoc = readFile(repo / "sdk/src/logos_sdk/contracts/lcn_storage_fetch.cddl")
    fakeSet = acceptContractSet(
      readFile(repo / "sdk/src/logos_sdk/testing/fixtures/fetch_fake_module.cddl"),
      [contractDoc],
    ).tryGet
    fakeRoot = fakeSet.primary.root
    fakeSchema = encodeCbor(schemaResponse(fakeSet, fakeRoot).tryGet)
    # [G490; PM App A] The contract from the pinned documents, never from the kit.
    pmSet = acceptContractSet(
      core_pins.PackageManagerContractDocument,
      [],
      [core_pins.PackageManifestDocument, cfgTypesDoc],
      AcceptOptions(system: true),
    ).tryGet
    pmRoot = pmSet.primary.root
    pmSchema = encodeCbor(schemaResponse(pmSet, pmRoot).tryGet)

  proc digestOf(path: string): array[32, byte] =
    let bytes = readFile(path)
    blake3(bytes.toOpenArrayByte(0, bytes.high))

  let
    fakeDigest = digestOf(fakeLib)
    pmDigest = digestOf(pmLib)

  # The packages, signed once, with a variant for each host the suite runs on: `app`
  # depends on `lib` (compatible with 1.0.0), and two `lib` versions are in the catalog, so
  # that the installed order's descending versions show.
  const Hosts = [
    ("linux-x86_64", "linux", "x86_64"),
    ("linux-aarch64", "linux", "aarch64"),
    ("darwin-aarch64", "darwin", "aarch64"),
    ("darwin-x86_64", "darwin", "x86_64"),
  ]
  let
    (orgKey, orgPub) = testKey(1)
    app100 =
      packed(dataManifest("app", "1.0.0", [("lib", "1.0.0")], Hosts), "org", orgKey)
    lib120 = packed(dataManifest("lib", "1.2.0", variants = Hosts), "org", orgKey)
    lib130 = packed(dataManifest("lib", "1.3.0", variants = Hosts), "org", orgKey)
    example = modulePackage(allHosts = true).packed("org", orgKey)
    trust =
      trustOf([anchorOf("org", ["app", "lib", "logos.example"], orgPub)]).trustBytes
    objects = @[
      ("app-1.0.0", app100),
      ("lib-1.2.0", lib120),
      ("lib-1.3.0", lib130),
      ("logos.example-1.0.0", example),
    ]
    # The catalog's canonical order (`entryOrder`): name, then descending version.
    catalogEntries = @[
      entryOf("app", "1.0.0", locator = "fetch-fake/state/app-1.0.0"),
      entryOf("lib", "1.3.0", locator = "fetch-fake/state/lib-1.3.0"),
      entryOf("lib", "1.2.0", locator = "fetch-fake/state/lib-1.2.0"),
      entryOf(
        "logos.example", "1.0.0", locator = "fetch-fake/state/logos.example-1.0.0"
      ),
    ]
    document = catalogBytes(catalogEntries)

  proc pmInputBytes(readers: seq[string]): seq[byte] =
    ## [G498] The protected input `logosd` would compose with `readers`.
    var v = pmValue(
      trust,
      document,
      bindings = [("main", "hf")],
      catalogLocator = "fetch-fake/state/catalog",
    )
    v.readers = Opt.some(readers)
    v.runtime_instance_id = Opt.some(RuntimeId)
    v.encode.tryGet

  proc hosted(env: openArray[string] = [], readers = @["c", "d"]): EngineConfig =
    ## `config` with the Runtime id, a state root, the Module Host program and the
    ## environment names `env` passed to it, a short endpoint directory and the Package
    ## Manager's protected input naming `readers`; `pm` is the marked instance (G490).
    result = config()
    result.runtimeInstanceId = RuntimeId
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv & @env
    result.endpointDir = shortBase / ("e" & $engines)
    var t = fastConfig()
    t.helloTimeout = int64(Answer) * 1000 * Ms
    t.admissionTimeout = int64(Answer) * 1000 * Ms
    t.writeStallTimeout = 10_000 * Ms * Slow
    result.transport = Opt.some(t)
    result.shutdownGrace = initDuration(seconds = 10 * Slow)
    result.protectedInputs = @[("pm", pmInputBytes(readers))]
    result.packageManager = Opt.some("pm")

  proc stateDir(cfg: EngineConfig, state: string): string =
    result = cfg.stateRoot.get / state
    createDir(result)

  proc stock(cfg: EngineConfig) =
    ## The fake's `objects/`: the catalog and the archives, written before the start.
    let dir = cfg.stateDir("f") / "objects"
    createDir(dir)
    writeFile(dir / "catalog", textOf(document))
    for (name, bytes) in objects:
      writeFile(dir / name, textOf(bytes))

  proc fakeRecord(): ModuleRecord =
    ModuleRecord(
      module: "fetch_fake_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "fetchfake", localPath: fakeLib, hash: fakeDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(fakeRoot),
      implements: @[LcnStorageFetchRoot],
      stateAssignment: Opt.some("f"),
    )

  proc pmRecord(): ModuleRecord =
    ## [G491] The record `logosd` composes for the Package Manager, here under `pm`.
    ModuleRecord(
      module: PmModule,
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: PmModule, localPath: pmLib, hash: pmDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(pmRoot),
      stateAssignment: Opt.some("p"),
    )

  proc startedLogging(
      e: Engine, r: ModuleRecord, instance, path: string
  ): InstanceView =
    ## `instance` started with its Module Host's fd 2 on `path`.
    flushFile(stderr)
    let saved = dup(2)
    let fd = posix.open(cstring(path), O_WRONLY or O_CREAT or O_APPEND, 0o600)
    doAssert saved >= 0 and fd >= 0
    discard dup2(fd, 2)
    discard posix.close(fd)
    try:
      result = e.started(r, instance)
    finally:
      flushFile(stderr)
      discard dup2(saved, 2)
      discard posix.close(saved)

  proc linesWith(path, text: string): seq[string] =
    ## The lines of the module's log at `path` that hold `text`.
    if fileExists(path):
      for l in readFile(path).splitLines:
        if text in l:
          result.add(l)

  # The clients' handles: the fake's driver, and a route to the Package Manager from each
  # of `c` and `d` (readers) and `x` (not one).
  var driver, pm, pmD, pmX: LogosRouteHandle
  var opened = 0

  proc open(
      rc: ptr LogosRuntimeControlBinding, root: Digest, schema: seq[byte]
  ): LogosRouteHandle =
    inc opened
    let made = rc.establish("k" & $opened, root)
    check made.code == ecOk
    if made.code != ecOk:
      return
    let (code, h) = rc.materialize(made.routesOf.routes[0].route, root, schema)
    check code == ecOk
    h

  proc releaseAll() =
    for h in [addr driver, addr pm, addr pmD, addr pmX]:
      if h[].vtable != nil:
        h[].release()
      h[] = LogosRouteHandle()

  proc drive(to: FetchFakeSetReadinessRequestReadinessChoiceKind): bool =
    invoke(
      addr driver,
      FetchFakeSetReadinessRequest(
        readiness: FetchFakeSetReadinessRequestReadinessChoice(kind: to)
      ),
    ).isOk

  # Requests and replies ----------------------------------------------------------------

  func rootRequest(package, version: string): CborValue =
    cborMap((cbor("package"), cbor(package)), (cbor("version"), cbor(version)))

  proc call(h: var LogosRouteHandle, meth: string, request: CborValue): RcResult =
    raw(h, meth, encodeCbor(request))

  proc canonical(bytes: seq[byte]): bool =
    ## [G494] A reply is one deterministic-CBOR value: its own encoding.
    let v = decodeCbor(bytes)
    v.isOk and encodeCbor(v.get) == bytes

  proc valueOf(r: RcResult): CborValue =
    ## The reply's value; a failed call or a reply that is not its own encoding fails here.
    result = cborMap()
    check r.code == ecOk
    checkpoint r.message
    check canonical(r.response)
    let v = decodeCbor(r.response)
    if v.isOk:
      result = v.get

  func codeOf(v: CborValue): string =
    ## The reply's `package_error` code; empty for a success.
    let e = v.lookup("error")
    if e.isSome:
      let c = e.get.lookup("code")
      if c.isSome:
        return c.get.getText.get("")

  func installedOf(v: CborValue): CborValue =
    ## `{installed: record}`'s record; an empty map for another reply.
    v.lookup("installed").get(cborMap())

  func packagesOf(v: CborValue): seq[CborValue] =
    ## A page's records.
    let p = v.lookup("packages")
    if p.isSome and p.get.kind == ckArray:
      return p.get.items

  func nextOf(v: CborValue): string =
    ## A page's `next_cursor`; empty when it has none.
    let n = v.lookup("next_cursor")
    if n.isSome:
      return n.get.getText.get("")

  func idOf(record: CborValue): string =
    ## A record's or a catalog entry's identity, as `package@version`.
    let id = record.lookup("identity").get(cborMap())
    id.lookup("package").get(cbor("")).getText.get("") & "@" &
      id.lookup("version").get(cbor("")).getText.get("")

  proc listQuery(cursor = "", limit = -1, package = ""): CborValue =
    var e: seq[(CborValue, CborValue)]
    if cursor.len > 0:
      e.add((cbor("cursor"), cbor(cursor)))
    if limit >= 0:
      e.add((cbor("limit"), cbor(uint64(limit))))
    if package.len > 0:
      e.add((cbor("package"), cbor(package)))
    cborMap(e)

  proc pageOf(
      h: var LogosRouteHandle, meth: string, cursor = "", limit = -1, package = ""
  ): CborValue =
    ## One page of `meth` (`list_packages` or `list_installed_packages`).
    h.call(meth, listQuery(cursor, limit, package)).valueOf

  proc walkPages(
      h: var LogosRouteHandle, meth: string, limit = -1, package = ""
  ): (seq[CborValue], int) =
    ## Every record of a listing, its pages followed by `next_cursor`; and how many pages.
    var cursor = ""
    while true:
      let v = h.pageOf(meth, cursor, limit, package)
      check v.codeOf == ""
      result[0].add(v.packagesOf)
      inc result[1]
      cursor = v.nextOf
      if cursor.len == 0 or result[1] > 100:
        break

  proc installRecord(package, version: string): CborValue =
    ## `package@version` installed through `c`'s route: its record.
    pm.call("install_package", rootRequest(package, version)).valueOf.installedOf

  proc acquired(): bool =
    ## The catalog is in use: `app`'s inspection succeeds.
    waitUntil(
      proc(): bool =
        let r = pm.call("inspect_package", rootRequest("app", "1.0.0"))
        r.code == ecOk and decodeCbor(r.response).isOk and
          decodeCbor(r.response).get.lookup("inspection").isSome,
      Answer,
    )

  type Setup = object
    e: Engine
    log: string
    rc, rcD: ptr LogosRuntimeControlBinding

  proc setup(cfg: EngineConfig, name: string): Setup =
    ## The fake and the marked Package Manager started, the fake ready, the catalog in use,
    ## a route from each of `c`, `d` and `x`; the module's operator lines go to
    ## `<work>/<name>.log`.
    cfg.stock()
    result.log = work / (name & ".log")
    removeFile(result.log)
    result.e = fixtureEngine(cfg)
    discard result.e.started(fakeRecord(), "hf")
    check result.e.startedLogging(pmRecord(), "pm", result.log).state == msReady
    result.rc = result.e.startClient("c")[1]
    driver = result.rc.open(fakeRoot, fakeSchema)
    pm = result.rc.open(pmRoot, pmSchema)
    result.rcD = result.e.startClient("d")[1]
    pmD = result.rcD.open(pmRoot, pmSchema)
    pmX = result.e.startClient("x")[1].open(pmRoot, pmSchema)
    check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
    check acquired()

  # The transport consumer, for the cases that hold calls in flight -----------------------

  type Direct = object
    path: string
    ticket: RouteTicket

  proc directOf(rc: ptr LogosRuntimeControlBinding): Direct =
    ## A route to the Package Manager, used directly: its invocation descriptor.
    inc opened
    let made = rc.establish("k" & $opened, pmRoot)
    doAssert made.code == ecOk, made.message
    let d = made.routesOf.routes[0].invocation
    doAssert d.isSome
    let i = d.get
    doAssert i.kind == LogosNSRuntimeControlInvocationDescriptorKind.Case0 and
      i.arm_0.ticket.len == TicketBytes
    result.path = i.arm_0.path
    copyMem(addr result.ticket[0], unsafeAddr i.arm_0.ticket[0], TicketBytes)

  var nextConn, nextTag: uint64

  proc seen(o: Owner, pred: proc(ev: IoEvent): bool, timeoutMs = Wait): Opt[IoEvent] =
    let until = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while true:
      for ev in o.log:
        if pred(ev):
          return Opt.some(ev)
      if getMonoTime() >= until:
        return Opt.none(IoEvent)
      discard o.pump(10)

  proc session(o: Owner, d: Direct): ConnId =
    inc nextConn
    let conn = nextConn
    o.connect(
      conn,
      d.path,
      d.ticket,
      module = PmModule,
      selected = ContractInput(root: pmRoot, schema: pmSchema, system: true),
    )
    let ev = o.seen(
      proc(ev: IoEvent): bool =
        ev.conn == conn and ev.kind in {evConnected, evConnectFailed}
    )
    check ev.isSome and ev.get.kind == evConnected
    conn

  proc send(o: Owner, conn: ConnId, meth: string, request: CborValue): uint64 =
    inc nextTag
    o.call(conn, nextTag, meth, request)
    nextTag

  proc outcome(
      o: Owner, conn: ConnId, tag: uint64, timeoutMs = Wait
  ): Opt[CallOutcome] =
    let ev = o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == evResponse and ev.conn == conn and ev.tag == tag,
      timeoutMs,
    )
    if ev.isNone:
      Opt.none(CallOutcome)
    else:
      Opt.some(ev.get.outcome)

  suite "the Package Manager's queries, hosted (G498, G499, G500)":
    teardown:
      releaseAll()
      leftover()

    test "[PKG-0525] [PKG-0527] [PKG-0529] [PKG-0530] [PKG-0531] [PKG-0532] [PKG-0386] [IMPL-DECISION G498] [IMPL-DECISION G495] [IMPL-DECISION G501] a caller the protected input does not name as a reader: list_packages, list_installed_packages, get_runtime_handoff and watch_installed_packages end MODULE_ERROR with no message and no detail, one operator line each naming the caller; the readers are answered":
      let s = setup(hosted(), "nonreader")
      let handoff = cborMap(
        (cbor("module"), cbor("alpha_module")),
        (cbor("package"), rootRequest("logos.example", "1.0.0")),
      )
      let methods = [
        "list_packages", "list_installed_packages", "get_runtime_handoff",
        "watch_installed_packages",
      ]
      let requests = [cborMap(), cborMap(), handoff, cborMap()]
      for i, meth in methods:
        checkpoint meth
        let r = pmX.call(meth, requests[i])
        check r.code == ecModule
        check r.message == ""
        check r.detail.len == 0
        check r.response.len == 0
      check waitUntil(
        proc(): bool =
          s.log.linesWith("refused for").len == 4
      )
      for meth in methods:
        let lines = s.log.linesWith(
          "package-manager: " & meth & " refused for module instance x of Runtime " &
            RuntimeId & ": not a reader"
        )
        checkpoint meth & ": " & $s.log.linesWith("refused for")
        check lines.len == 1
      # [Fable §17.3 point 3] The same refusal again within a minute is counted, not
      # written: a caller cannot write the operator's log at its own call rate. Each
      # line is written before its refusal is answered.
      for _ in 0 ..< 5:
        check pmX.call("list_packages", cborMap()).code == ecModule
      check s.log.linesWith("refused for").len == 4
      # The readers: answered, and a reader's handoff of what is not installed is the
      # package error the binding's would be.
      check pm.pageOf("list_packages").packagesOf.len == 4
      check pmD.pageOf("list_installed_packages").packagesOf.len == 0
      check pmD.call("get_runtime_handoff", handoff).valueOf.codeOf ==
        "package-not-installed"
      releaseAll()
      s.e.finish()

    test "[PKG-0368] [PKG-0638] [PKG-0381] [PKG-0384] [PKG-0533] [SPEC PM l.1656-1657] [IMPL-DECISION G500] list_packages: the catalog's listed entries in its canonical order, each the entry's encoding; pages of one follow next_cursor to the same records, which is absent exactly on the last page; the package filter; limit 0 and 1001 are invalid-request":
      let s = setup(hosted(), "packages")
      let expect = catalogEntries.mapIt(it.toCbor)
      let all = pm.pageOf("list_packages")
      check all.packagesOf == expect
      check all.lookup("next_cursor").isNone
      check pm.walkPages("list_packages", limit = 1) == (expect, 4)
      check pm.walkPages("list_packages", limit = 3) == (expect, 2)
      check pm.walkPages("list_packages", limit = 1, package = "lib") ==
        (expect[1 .. 2], 2)
      check pm
        .pageOf("list_packages", limit = 2, package = "lib")
        .lookup("next_cursor").isNone
      let none = pm.pageOf("list_packages", package = "none")
      check none.packagesOf.len == 0 and none.lookup("next_cursor").isNone
      for limit in [0, 1001]:
        check pm.pageOf("list_packages", limit = limit).codeOf == "invalid-request"
        check pm.pageOf("list_installed_packages", limit = limit).codeOf ==
          "invalid-request"
      releaseAll()
      s.e.finish()

    test "[PKG-0167] [PKG-0378] [PKG-0648] [PKG-0384] [PKG-0533] [SPEC PM l.1659-1660] [IMPL-DECISION G500] list_installed_packages: one snapshot's records in name order and descending versions, each the record install_package answered, with no provenance claimed; pages of one; the package filter":
      let s = setup(hosted(), "installed")
      let empty = pm.pageOf("list_installed_packages")
      check empty.packagesOf.len == 0 and empty.lookup("next_cursor").isNone
      let app = installRecord("app", "1.0.0")
      let lib13 = installRecord("lib", "1.3.0")
      let lib12 = installRecord("lib", "1.2.0")
      let expect = @[app, lib13, lib12]
      check expect.mapIt(it.idOf) == @["app@1.0.0", "lib@1.3.0", "lib@1.2.0"]
      let all = pm.pageOf("list_installed_packages")
      check all.packagesOf == expect
      check all.lookup("next_cursor").isNone
      for r in all.packagesOf:
        check r.entries.mapIt(it[0].getText.get("")).sorted == @RecordKeys
      check pm.walkPages("list_installed_packages", limit = 1) == (expect, 3)
      check pm.walkPages("list_installed_packages", limit = 2) == (expect, 2)
      check pm.walkPages("list_installed_packages", limit = 1, package = "lib") ==
        (expect[1 .. 2], 2)
      check pm.pageOf("list_installed_packages", package = "logos.example").packagesOf.len ==
        0
      releaseAll()
      s.e.finish()

    test "[PKG-0384] [PKG-0385] [PKG-0387] [PKG-0528] [PKG-0542] [SPEC PM l.1645-1654] [IMPL-DECISION G499] a cursor is its origin's and its query's: another reader, the other list, another filter and a spent token are invalid-request, and the owner's continuation still goes on; a commit between pages expires an installed listing's cursor, not a catalog listing's; a new realization knows none of the old cursors":
      let s = setup(hosted(), "cursors")
      discard installRecord("app", "1.0.0")
      let first = pm.pageOf("list_installed_packages", limit = 1)
      check first.packagesOf.mapIt(it.idOf) == @["app@1.0.0"]
      let token = first.nextOf
      check token.len == 43
      let refused = pmD.pageOf("list_installed_packages", cursor = token, limit = 1)
      check refused.codeOf == "invalid-request"
      check refused.lookup("error").get(cborMap()).lookup("message") ==
        Opt.some(
          cbor(
            "the cursor is not valid for this query, or has expired: start the listing again"
          )
        )
      check pm.pageOf("list_packages", cursor = token, limit = 1).codeOf ==
        "invalid-request"
      check pm.pageOf(
        "list_installed_packages", cursor = token, limit = 1, package = "lib"
      ).codeOf == "invalid-request"
      let second = pm.pageOf("list_installed_packages", cursor = token, limit = 1)
      check second.packagesOf.mapIt(it.idOf) == @["lib@1.3.0"]
      check second.lookup("next_cursor").isNone
      check pm.pageOf("list_installed_packages", cursor = token, limit = 1).codeOf ==
        "invalid-request"
      # A commit between pages: the installed listing's cursor has expired; the catalog's
      # has not, since the catalog in use is the same.
      let installed = pm.pageOf("list_installed_packages", limit = 1).nextOf
      let catalog = pm.pageOf("list_packages", limit = 1).nextOf
      check installed.len > 0 and catalog.len > 0
      discard installRecord("lib", "1.2.0")
      check pm.pageOf("list_installed_packages", cursor = installed, limit = 1).codeOf ==
        "invalid-request"
      check pm.pageOf("list_packages", cursor = catalog, limit = 1).packagesOf.mapIt(
        it.idOf
      ) == @["lib@1.3.0"]
      # [PKG-0528] Stopped and started again: the new realization knows no cursor of the old.
      let kept = pm.pageOf("list_installed_packages", limit = 1).nextOf
      check kept.len > 0
      pm.release()
      pm = LogosRouteHandle()
      check s.e.stop("pm").isOk
      check waitUntil(
        proc(): bool =
          s.e.view("pm").tryGet.state == msUnloaded,
        Answer,
      )
      check s.e.start("pm").tryGet.state == msReady
      pm = s.rc.open(pmRoot, pmSchema)
      check acquired()
      check pm.pageOf("list_installed_packages", cursor = kept, limit = 1).codeOf ==
        "invalid-request"
      check pm.pageOf("list_installed_packages").packagesOf.len == 3
      releaseAll()
      s.e.finish()

    test "[PKG-0383] [IMPL-DECISION G500] the page byte budget (LCN_TEST_PM_PAGE_BUDGET = 1): every page holds one record, whatever the limit, and next_cursor goes on to the rest":
      putEnv("LCN_TEST_PM_PAGE_BUDGET", "1")
      defer:
        delEnv("LCN_TEST_PM_PAGE_BUDGET")
      let s = setup(hosted(["LCN_TEST_PM_PAGE_BUDGET"]), "budget")
      let expect = @[
        installRecord("app", "1.0.0"),
        installRecord("lib", "1.3.0"),
        installRecord("lib", "1.2.0"),
      ]
      check pm.walkPages("list_installed_packages") == (expect, 3)
      check pm.walkPages("list_installed_packages", limit = 1000) == (expect, 3)
      check pm.walkPages("list_packages") == (catalogEntries.mapIt(it.toCbor), 4)
      releaseAll()
      s.e.finish()

    test "[PKG-0383] [IMPL-DECISION G500] the page byte budget against limit: a page cut by the budget before limit, a page cut by limit before the budget, and a record over the budget alone in its page, the next page going on after it":
      # A Module Host's environment is copied when the engine is made (R4), so each budget
      # has a setup of its own; the first, with the default budget, measures the records.
      proc installAll(): seq[CborValue] =
        # In the listing's order: package name, then descending version.
        @[
          installRecord("app", "1.0.0"),
          installRecord("lib", "1.3.0"),
          installRecord("lib", "1.2.0"),
          installRecord("logos.example", "1.0.0"),
        ]

      proc sizesOf(r: seq[CborValue]): seq[int] =
        r.mapIt(encodeCbor(it).len)

      var size: seq[int]
      block:
        let s = setup(hosted(["LCN_TEST_PM_PAGE_BUDGET"]), "budgets")
        size = installAll().sizesOf
        releaseAll()
        s.e.finish()
      # What the cases rest on: `app`'s record (it names a dependency) is larger than a
      # `lib` one, and the module package's is larger than both `lib` ones together.
      check size[0] > size[1] and size[0] > size[2]
      check size[3] > size[1] + size[2]
      defer:
        delEnv("LCN_TEST_PM_PAGE_BUDGET")

      # The budget holds the two `lib` records exactly.
      putEnv("LCN_TEST_PM_PAGE_BUDGET", $(size[1] + size[2]))
      block:
        let s = setup(hosted(["LCN_TEST_PM_PAGE_BUDGET"]), "budgets-a")
        let r = installAll()
        check r.sizesOf == size # the records measured are these
        # Cut by the budget before `limit`: `app` alone, since `lib 1.3.0` would take the
        # page past it; then both `lib` records, since the module package's would.
        let a1 = pm.pageOf("list_installed_packages", limit = 1000)
        check a1.packagesOf == r[0 .. 0]
        let a2 = pm.pageOf("list_installed_packages", cursor = a1.nextOf, limit = 1000)
        check a2.packagesOf == r[1 .. 2]
        # Over the budget, alone in its page, which ends the listing.
        let a3 = pm.pageOf("list_installed_packages", cursor = a2.nextOf, limit = 1000)
        check a3.packagesOf == r[3 .. 3]
        check a3.lookup("next_cursor").isNone
        # Cut by `limit` before the budget, which would take both `lib` records.
        let l1 = pm.pageOf("list_installed_packages", limit = 1)
        check l1.packagesOf == r[0 .. 0]
        let l2 = pm.pageOf("list_installed_packages", cursor = l1.nextOf, limit = 1)
        check l2.packagesOf == r[1 .. 1]
        check l2.nextOf.len > 0
        # The catalog's entries are far smaller than the budget: `limit` cuts its page.
        let c1 = pm.pageOf("list_packages", limit = 3)
        check c1.packagesOf == catalogEntries[0 .. 2].mapIt(it.toCbor)
        check c1.nextOf.len > 0
        releaseAll()
        s.e.finish()

      # A budget below `app`'s record: it goes alone in the first page, over the budget,
      # and the next page goes on after it.
      putEnv("LCN_TEST_PM_PAGE_BUDGET", $(size[0] - 1))
      block:
        let s = setup(hosted(["LCN_TEST_PM_PAGE_BUDGET"]), "budgets-b")
        let r = installAll()
        check r.sizesOf == size
        let b1 = pm.pageOf("list_installed_packages", limit = 1000)
        check b1.packagesOf == r[0 .. 0]
        let b2 = pm.pageOf("list_installed_packages", cursor = b1.nextOf, limit = 1000)
        check b2.packagesOf.len >= 1
        if b2.packagesOf.len >= 1:
          check b2.packagesOf[0] == r[1]
        check pm.walkPages("list_installed_packages", limit = 1000)[0] == r
        releaseAll()
        s.e.finish()

    test "[PKG-0558] [IMPL-DECISION G500] page jobs: past 2 in flight for one reader the call is MODULE_ERROR with no message and one operator line naming the bound, while another reader's goes on; the first worker is not behind them, so an install is answered while they wait; each page is its own snapshot's":
      putEnv("LCN_TEST_PM_PAGE_PACE_MS", $PaceMs)
      defer:
        delEnv("LCN_TEST_PM_PAGE_PACE_MS")
      let s = setup(hosted(["LCN_TEST_PM_PAGE_PACE_MS"]), "bound")
      discard installRecord("app", "1.0.0")
      let o = newOwner(fastConfig())
      defer:
        o.stop()
      let conn = o.session(s.rc.directOf())
      let connD = o.session(s.rcD.directOf())
      let request = listQuery(limit = 1)
      var sent: seq[uint64]
      for i in 1 .. 3:
        sent.add(o.send(conn, "list_installed_packages", request))
      # The three are concurrent and reach the engine in no set order: the refused one is
      # whichever came last.
      var answered: seq[uint64]
      check waitUntil(
        proc(): bool =
          discard o.pump(10)
          answered = sent.filterIt(o.outcome(conn, it, 0).isSome)
          answered.len > 0,
        Answer,
      )
      check answered.len == 1
      if answered.len > 0:
        let f = o.outcome(conn, answered[0], 0)
        check f.isSome and not f.get.ok
        if f.isSome and not f.get.ok:
          check f.get.failure.code == ecModule
          check f.get.failure.message.get("") == ""
      let other = o.send(connD, "list_installed_packages", request)
      # An operation on the first worker, answered while the pages wait on theirs.
      let started = getMonoTime()
      check installRecord("logos.example", "1.0.0").idOf == "logos.example@1.0.0"
      let took = getMonoTime() - started
      checkpoint "the install took " & $took
      let running = sent.filterIt(it notin answered)
      check running.len == 2
      for tag in running:
        check o.outcome(conn, tag, 0).isNone
      check o.outcome(connD, other, 0).isNone
      # Each page answers from the snapshot it began on: `app` and its `lib`, without
      # `logos.example`, and its next cursor has expired with that snapshot.
      for (c, tag) in [(conn, running[0]), (conn, running[1]), (connD, other)]:
        let r = o.outcome(c, tag)
        check r.isSome and r.get.ok
        if r.isSome and r.get.ok:
          check canonical(r.get.result)
          let v = decodeCbor(r.get.result).get(cborMap())
          check v.packagesOf.mapIt(it.idOf) == @["app@1.0.0"]
          let t = v.nextOf
          check t.len > 0
          if c == conn:
            check pm.pageOf("list_installed_packages", cursor = t, limit = 1).codeOf ==
              "invalid-request"
      check s.log.linesWith(
        "package-manager: list_installed_packages refused for module instance c of Runtime " &
          RuntimeId & ": at the page-job bound: 2 in flight for this caller"
      ).len == 1
      releaseAll()
      s.e.finish()

  # The watch and progress (5-6b-2; G501, G502) ---------------------------------------------

  const
    InstalledEvent = "logos.package_manager.installed_packages_changed_event"
    ProgressEvent = "logos.package_manager.operation_progress_event"
    Phases = ["resolving", "fetching", "verifying", "installing", "removing"]

  proc subscribed(o: Owner, conn: ConnId, event: string): bool =
    ## `event` subscribed to on `conn`, and the subscription answered with success.
    inc nextTag
    let id = nextTag
    o.subscribe(conn, id, event)
    let ev = o.seen(
      proc(ev: IoEvent): bool =
        ev.conn == conn and ev.kind == evSubscription and ev.subscriptionId == id
    )
    ev.isSome and ev.get.subscriptionFailure.isNone

  proc heard(o: Owner, conn: ConnId, event: string): seq[CborValue] =
    ## The `event`s delivered on `conn` so far, decoded.
    discard o.pump(0)
    for ev in o.log:
      if ev.kind == evEvent and ev.conn == conn and ev.eventName == event:
        result.add(decodeCbor(ev.eventData).get(cbor("not one CBOR value")))

  proc ended(o: Owner, conn: ConnId, tag: uint64, code: ErrorCode): bool =
    ## The call `tag` on `conn` ended with the invocation error `code`.
    let r = o.outcome(conn, tag)
    checkpoint "the call's outcome: " & (
      if r.isNone: "none"
      elif r.get.ok: "ok"
      else: $r.get.failure.code & " " & r.get.failure.message.get("")
    )
    r.isSome and not r.get.ok and r.get.failure.code == code

  proc admitted(log, instance: string, mine, all: int, count = 1): bool =
    ## The operator's log has `count` lines admitting a watch of `instance` as its `mine`th
    ## and the `all`th in all.
    log.linesWith(
      "package-manager: watch_installed_packages admitted for module instance " &
        instance & " of Runtime " & RuntimeId & ": " & $mine & " of 4 for this caller, " &
        $all & " of 16 in all"
    ).len == count

  suite "the Package Manager's watch and progress, hosted (G501, G502)":
    teardown:
      releaseAll()
      leftover()

    test "[PKG-0545] [PKG-0546] [PKG-0550] [PKG-0551] [PKG-0552] [PKG-0553] [PKG-0556] [PKG-0557] [PKG-0562] [PKG-0522] [PKG-0523] [PKG-0634] [PKG-0635] [IMPL-DECISION G501] a reader's watch: each landed change is one installed_packages_changed {} through the watch's own invocation, coalesced while one is in flight, heard on no other session, none for a no-op, one for a removal; the Runtime's cancel ends it CANCELLED and touches no operation; so does the loss of its session":
      let s = setup(hosted(), "watch")
      let o = newOwner(fastConfig())
      o.autoRelease = true
      defer:
        o.stop()
      let conn = o.session(s.rc.directOf())
      let other = o.session(s.rcD.directOf())
      check o.subscribed(conn, InstalledEvent)
      check o.subscribed(other, InstalledEvent)
      let watch = o.send(conn, "watch_installed_packages", cborMap())
      check waitUntil(
        proc(): bool =
          s.log.admitted("c", 1, 1),
        Answer,
      )
      # Two commits, `lib` then `app`: one hint, or two when the second landed after the
      # first hint was delivered.
      check installRecord("app", "1.0.0").idOf == "app@1.0.0"
      check waitUntil(
        proc(): bool =
          o.heard(conn, InstalledEvent).len >= 1,
        Answer,
      )
      o.settle(500 * Slow)
      let hints = o.heard(conn, InstalledEvent)
      check hints.len in 1 .. 2
      check hints.allIt(it == cborMap())
      check o.heard(other, InstalledEvent).len == 0
      check o.outcome(conn, watch, 0).isNone
      # The same install again commits nothing: no hint.
      check installRecord("app", "1.0.0").idOf == "app@1.0.0"
      o.settle(500 * Slow)
      check o.heard(conn, InstalledEvent).len == hints.len
      # A removal is one more.
      check pm.call(
        "remove_package", cborMap((cbor("identity"), rootRequest("app", "1.0.0")))
      ).valueOf.codeOf == ""
      check waitUntil(
        proc(): bool =
          o.heard(conn, InstalledEvent).len == hints.len + 1,
        Answer,
      )
      o.cancel(conn, watch)
      check o.ended(conn, watch, ecCancelled)
      check waitUntil(
        proc(): bool =
          s.log.linesWith("watch_installed_packages cancelled by the Runtime").len == 1,
        Answer,
      )
      check o.heard(other, InstalledEvent).len == 0
      # The Package Manager goes on: `lib` is still installed.
      let left = pm.pageOf("list_installed_packages").packagesOf.mapIt(it.idOf)
      check left.len == 1 and left.allIt(it.startsWith("lib@"))
      # [PKG-0556] Destination loss: the watch of a session that ends stops.
      let gone = o.session(s.rc.directOf())
      discard o.send(gone, "watch_installed_packages", cborMap())
      check waitUntil(
        proc(): bool =
          s.log.admitted("c", 1, 1, count = 2),
        Answer,
      )
      # The consumer closes its connection (a caller's session has no termination of
      # its own, TRANSPORT §8.1): the Runtime cancels its served invocations.
      o.send(IoCommand(conn: gone, kind: cmdClose))
      check waitUntil(
        proc(): bool =
          s.log.linesWith("watch_installed_packages cancelled by the Runtime").len == 2,
        Answer,
      )
      releaseAll()
      s.e.finish()

    test "[IMPL-DECISION G501] [IMPL-DECISION G495] a reader that opens and cancels watches in a loop: its admission lines and its cancel lines are written 8 times a minute each, the rest counted, and the counts written as the Package Manager stops, once another reader's watch shows every cancel has run":
      let s = setup(hosted(), "watchloop")
      let o = newOwner(fastConfig())
      o.autoRelease = true
      defer:
        o.stop()
      let conn = o.session(s.rc.directOf())
      check o.subscribed(conn, InstalledEvent)
      let head = "admitted for module instance c of Runtime " & RuntimeId
      let cancels =
        "cancelled by the Runtime for module instance c of Runtime " & RuntimeId
      proc round(o: Owner, n: int) =
        # Four watches, all admitted (seen by the log for the first two rounds, by one
        # hint each for the third), then cancelled.
        var tags: seq[uint64] = @[]
        for _ in 1 .. 4:
          tags.add(o.send(conn, "watch_installed_packages", cborMap()))
        if n < 3:
          check waitUntil(
            proc(): bool =
              s.log.linesWith(head).len == 4 * n,
            Answer,
          )
        else:
          o.settle(500 * Slow)
          check installRecord("lib", "1.3.0").idOf == "lib@1.3.0" # one commit
          check waitUntil(
            proc(): bool =
              o.heard(conn, InstalledEvent).len == 4,
            Answer,
          )
        for t in tags:
          o.cancel(conn, t)
        for t in tags:
          let tag = t
          check waitUntil(
            proc(): bool =
              o.ended(conn, tag, ecCancelled),
            Answer,
          )
        if n < 3:
          check waitUntil(
            proc(): bool =
              s.log.linesWith(cancels).len == 4 * n,
            Answer,
          )

      for n in 1 .. 3:
        o.round(n)
      # [Fable §17.9] The third round's cancel lines are counted, not written, and its
      # cancels reach the module in no set order. A watch gives its place back just after
      # its cancel line, so another reader's watch admitted as "1 of 16 in all" shows that
      # every one of `c`'s has run: `d` asks until it is (at most 8 times, so each of its
      # lines is written), and gives each place back before asking again.
      let other = o.session(s.rcD.directOf())
      var asked = 0
      while asked < 8:
        inc asked
        let probe = o.send(other, "watch_installed_packages", cborMap())
        let n = asked
        check waitUntil(
          proc(): bool =
            s.log.linesWith("watch_installed_packages admitted for module instance d ").len ==
              n,
          Answer,
        )
        let alone = s.log.admitted("d", 1, 1)
        o.cancel(other, probe)
        check o.ended(other, probe, ecCancelled)
        check waitUntil(
          proc(): bool =
            s.log.linesWith(
              "watch_installed_packages cancelled by the Runtime for module instance d "
            ).len == n,
          Answer,
        )
        if alone:
          break
      checkpoint "d asked " & $asked & " times"
      check s.log.admitted("d", 1, 1)
      # 8 of each of `c`'s kinds in the window; the third round's counted.
      check s.log.linesWith(head).len == 8
      check s.log.linesWith(cancels).len == 8
      # At the stop, the counts: the last line held of each kind, with the 3 others.
      releaseAll()
      s.e.finish()
      check s.log.linesWith(head).len == 9
      check s.log
        .linesWith(head)
        .filterIt(it.endsWith(" (3 more like it since its last line)")).len == 1
      check s.log.linesWith(cancels).len == 9
      check s.log
        .linesWith(cancels)
        .filterIt(it.endsWith(" (3 more like it since its last line)")).len == 1

    test "[PKG-0558] [PKG-0561] [IMPL-DECISION G501] watches: past 4 for one reader, and past 16 in all, the call is MODULE_ERROR with no message and one operator line naming the bound; equivalent watches on one session each hint once for one change; a watch that ends gives its place back":
      let s = setup(hosted(readers = @["c", "d", "e", "f", "g"]), "watches")
      let o = newOwner(fastConfig())
      o.autoRelease = true
      defer:
        o.stop()
      var conns = @[o.session(s.rc.directOf()), o.session(s.rcD.directOf())]
      for name in ["e", "f", "g"]:
        conns.add(o.session(s.e.startClient(name)[1].directOf()))
      var watches: seq[seq[uint64]]
      for i in 0 .. 3:
        var tags: seq[uint64]
        for k in 1 .. 4:
          tags.add(o.send(conns[i], "watch_installed_packages", cborMap()))
        watches.add(tags)
      check waitUntil(
        proc(): bool =
          s.log.linesWith("watch_installed_packages admitted for").len == 16,
        Answer,
      )
      check s.log
        .linesWith(" of 16 in all")
        .filterIt(it.endsWith(" 16 of 16 in all")).len == 1
      # [PKG-0561] One landed change: one hint from each of a session's four watches.
      for c in conns[0 .. 3]:
        check o.subscribed(c, InstalledEvent)
      check installRecord("logos.example", "1.0.0").idOf == "logos.example@1.0.0"
      check waitUntil(
        proc(): bool =
          conns[0 .. 3].allIt(o.heard(it, InstalledEvent).len == 4),
        Answer,
      )
      o.settle(300 * Slow)
      check conns[0 .. 3].allIt(o.heard(it, InstalledEvent).len == 4)
      let fifth = o.send(conns[0], "watch_installed_packages", cborMap())
      check o.ended(conns[0], fifth, ecModule)
      let g = o.send(conns[4], "watch_installed_packages", cborMap())
      check o.ended(conns[4], g, ecModule)
      for (c, tag) in [(conns[0], fifth), (conns[4], g)]:
        let r = o.outcome(c, tag, 0)
        if r.isSome:
          check r.get.failure.message.get("") == ""
      check s.log.linesWith(
        "package-manager: watch_installed_packages refused for module instance c of Runtime " &
          RuntimeId & ": at the watch bound: 4 in flight for this caller"
      ).len == 1
      check s.log.linesWith(
        "package-manager: watch_installed_packages refused for module instance g of Runtime " &
          RuntimeId & ": at the watch bound: 16 in flight in all"
      ).len == 1
      # One of `c`'s ends: `g` is admitted in its place.
      o.cancel(conns[0], watches[0][0])
      check o.ended(conns[0], watches[0][0], ecCancelled)
      # The caller has its CANCELLED from the Runtime first; the place is given back
      # once the Package Manager's watch has seen the cancel.
      check waitUntil(
        proc(): bool =
          s.log.linesWith("watch_installed_packages cancelled by the Runtime").len == 1,
        Answer,
      )
      let again = o.send(conns[4], "watch_installed_packages", cborMap())
      check waitUntil(
        proc(): bool =
          s.log.admitted("g", 1, 16),
        Answer,
      )
      o.cancel(conns[4], again)
      check o.ended(conns[4], again, ecCancelled)
      for i in 0 .. 3:
        for tag in watches[i]:
          if i == 0 and tag == watches[0][0]:
            continue
          o.cancel(conns[i], tag)
          check o.ended(conns[i], tag, ecCancelled)
      releaseAll()
      s.e.finish()

    test "[PKG-0564] [PKG-0565] [PKG-0566] [PKG-0567] [PKG-0568] [PKG-0569] [PKG-0570] [PKG-0571] [PKG-0572] [PKG-0520] [PKG-0524] [PKG-0632] [PKG-0636] [IMPL-DECISION G502] a reader's install and remove with a progress_key: operation_progress through the operation's own invocation, the key echoed, resolving first, counters within their totals; heard on no other session; none without a key, and none for a caller that is not a reader":
      let s = setup(hosted(), "progress")
      let o = newOwner(fastConfig())
      o.autoRelease = true
      defer:
        o.stop()
      let conn = o.session(s.rc.directOf())
      let other = o.session(s.rc.directOf())
      let notReader = o.session(s.e.startClient("y")[1].directOf())
      for c in [conn, other, notReader]:
        check o.subscribed(c, ProgressEvent)

      proc installWith(c: ConnId, package, version, key: string): bool =
        var e = @[(cbor("package"), cbor(package)), (cbor("version"), cbor(version))]
        if key.len > 0:
          e.add((cbor("progress_key"), cbor(key)))
        let r = o.outcome(c, o.send(c, "install_package", cborMap(e)))
        r.isSome and r.get.ok and
          decodeCbor(r.get.result).get(cborMap()).lookup("installed").isSome

      proc checked(events: seq[CborValue], key: string) =
        for v in events:
          check v.lookup("progress_key") == Opt.some(cbor(key))
          let phase = v.lookup("phase").get(cbor("")).getText.get("")
          check phase in Phases
          let done = v.lookup("bytes_completed")
          let total = v.lookup("bytes_total")
          if done.isSome and total.isSome:
            let (d, t) = (done.get.getUint64, total.get.getUint64)
            check d.isSome and t.isSome
            if d.isSome and t.isSome:
              check d.get <= t.get

      check conn.installWith("app", "1.0.0", "k1")
      let first = o.heard(conn, ProgressEvent)
      checkpoint "the phases: " &
        first.mapIt(it.lookup("phase").get(cbor("")).getText.get("")).join(", ")
      check first.len >= 1
      if first.len > 0:
        check first[0].lookup("phase") == Opt.some(cbor("resolving"))
      first.checked("k1")
      check o.heard(other, ProgressEvent).len == 0
      # The remove's: `removing`, with no counters.
      let tag = o.send(
        conn,
        "remove_package",
        cborMap(
          (cbor("identity"), rootRequest("app", "1.0.0")),
          (cbor("progress_key"), cbor("k2")),
        ),
      )
      let removed = o.outcome(conn, tag)
      check removed.isSome and removed.get.ok
      let second = o.heard(conn, ProgressEvent)[first.len ..^ 1]
      check second.len == 1
      second.checked("k2")
      if second.len == 1:
        check second[0].lookup("phase") == Opt.some(cbor("removing"))
        check second[0].lookup("bytes_completed").isNone
        check second[0].lookup("bytes_total").isNone
      # Without a key, and for a caller that is not a reader: none.
      let heardBefore = o.heard(conn, ProgressEvent).len
      check conn.installWith("logos.example", "1.0.0", "")
      check notReader.installWith("app", "1.0.0", "k3")
      o.settle(300 * Slow)
      check o.heard(conn, ProgressEvent).len == heardBefore
      check o.heard(notReader, ProgressEvent).len == 0
      check o.heard(other, ProgressEvent).len == 0
      releaseAll()
      s.e.finish()
