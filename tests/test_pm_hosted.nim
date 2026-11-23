## The Package Manager's shell hosted (Tier 5 step 5-3b-2; DECISIONS G405, G400, G401, G402;
## docs/PACKAGE-MANAGER.md §5): `pmtest_module` (`tests/kit/pmtest_impl.nim`, the shell under a
## test name) and the reference fake (`fetch_fake_module`) both realized `hosted_dynamic` under a
## test Runtime. The fake serves a catalog and signed archives from its state directory
## (`fetch-fake/state/<name>`, Q1 (c)); the Package Manager gets its `lcn.pm_input` as its
## protected realization input (G400); the test's client drives the fake and asks the probe.

import std/[atomics, monotimes, os, strutils, tables, times, typedthreads]
import unittest2
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

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "pm-hosted" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

when defined(posix):
  import logos_sdk/crypto/blake3
  import ./support/[modulehostbuild, pmfixture, sanitizerenv, shortdir]
  import ../src/logos_core/package/trustdoc_types
  import ../src/logos_core/pm/[catalog, input_types]
  from ./support/trnowner import fastConfig, Ms
  from ../src/logos_core/runtime/hostsup import traceMarkers, traced
  from logos_sdk/testing/generated/fetch_fake_module_calls import
    invoke, FetchFakeSetReadinessRequest, FetchFakeSetReadinessRequestReadinessChoice,
    FetchFakeSetReadinessRequestReadinessChoiceKind
  import logos_sdk/contracts/generated/lcn_NS_storage_fetch_calls
  import ./generated/pmtest_module_calls
  from ../src/logos_core/runtime/protinput import writeProtectedInput
  from ../src/logos_core/pm/shell import openShell
  from logos_sdk/codegen/kitrt import ModuleInit

  var logged {.threadvar.}: seq[string]

  proc capture(line: string) {.nimcall, gcsafe, raises: [].} =
    logged.add(line)

  const Answer = 60 * Slow ## seconds: bounds a wait for the Package Manager

  let
    hostProgram = moduleHostProgram()
    fakeLib = buildKitLibrary("fetch_fake_impl.nim", "pmhfake")
    pmLib = buildKitLibrary("pmtest_impl.nim", "pmhpm")
    shortBase = makeShortBase("lcnpm", "/e999/12345678/logos_fetch_fake_module.sock")
    contractDoc = readFile(repo / "sdk/src/logos_sdk/contracts/lcn_storage_fetch.cddl")
    fakeSet = acceptContractSet(
      readFile(repo / "sdk/src/logos_sdk/testing/fixtures/fetch_fake_module.cddl"),
      [contractDoc],
    ).tryGet
    fakeRoot = fakeSet.primary.root
    fakeSchema = encodeCbor(schemaResponse(fakeSet, fakeRoot).tryGet)
    pmSet = acceptContractSet(readFile(repo / "tests/kit/pmtest_module.cddl")).tryGet
    pmRoot = pmSet.primary.root
    pmSchema = encodeCbor(schemaResponse(pmSet, pmRoot).tryGet)

  proc digestOf(path: string): array[32, byte] =
    let bytes = readFile(path)
    blake3(bytes.toOpenArrayByte(0, bytes.high))

  let
    fakeDigest = digestOf(fakeLib)
    pmDigest = digestOf(pmLib)

  # The packages: signed once (each signature takes about a second), with a variant for each
  # host the suite runs on.
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
    orgTrust = trustOf([anchorOf("org", ["app", "lib"], orgPub)]).trustBytes
    objects = @[("app-1.0.0", app100), ("lib-1.2.0", lib120)]
    entries = @[
      entryOf("app", "1.0.0", locator = "fetch-fake/state/app-1.0.0"),
      entryOf("lib", "1.2.0", locator = "fetch-fake/state/lib-1.2.0"),
    ]
    document = catalogBytes(entries)

  proc pmInputBytes(trust = orgTrust): seq[byte] =
    pmValue(
      trust,
      document,
      bindings = [("main", "hf")],
      catalogLocator = "fetch-fake/state/catalog",
    ).encode.tryGet

  proc hosted(input: seq[byte]): EngineConfig =
    ## `config` with a state root, the Module Host program, a short endpoint directory and the
    ## Package Manager's protected input, as `test_storage_fetch` makes it.
    result = config()
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    result.endpointDir = shortBase / ("e" & $engines)
    var t = fastConfig()
    t.helloTimeout = int64(Answer) * 1000 * Ms
    t.admissionTimeout = int64(Answer) * 1000 * Ms
    t.writeStallTimeout = 10_000 * Ms * Slow
    result.transport = Opt.some(t)
    result.shutdownGrace = initDuration(seconds = 10 * Slow)
    result.protectedInputs = @[("pm", input)]

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
    ModuleRecord(
      module: "pmtest_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "pmtest", localPath: pmLib, hash: pmDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(pmRoot),
      stateAssignment: Opt.some("p"),
    )

  # The client's handles: the fake's driver, the fake's contract, the probe. Each is a route of
  # its own, so a hosted provider's ticket is used once (G258).
  var driver, fetch, probe: LogosRouteHandle
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
    for h in [addr driver, addr fetch, addr probe]:
      if h[].vtable != nil:
        h[].release()
      h[] = LogosRouteHandle()

  proc drive(to: FetchFakeSetReadinessRequestReadinessChoiceKind): bool =
    let r = invoke(
      addr driver,
      FetchFakeSetReadinessRequest(
        readiness: FetchFakeSetReadinessRequestReadinessChoice(kind: to), held: @[]
      ),
    )
    r.isOk

  proc status(): PmtestStatusResponse =
    let r = invoke(addr probe, PmtestStatusRequest())
    check r.isOk
    if r.isOk:
      result = r.get

  proc resolved(name, version: string): PmtestResolveResponse =
    let r = invoke(addr probe, PmtestResolveRequest(name: name, version: version))
    check r.isOk
    if r.isOk:
      result = r.get

  func packagesOf(r: PmtestResolveResponse): seq[string] =
    if r.kind == PmtestResolveResponseKind.Map_counters_packages:
      for p in r.arm_Map_counters_packages.packages:
        result.add(p.package & "@" & p.version)

  func errorOf(r: PmtestResolveResponse): string =
    if r.kind == PmtestResolveResponseKind.Map_error: r.arm_Map_error.error else: ""

  proc acquired(): bool =
    waitUntil(
      proc(): bool =
        status().catalog.isSome,
      Answer,
    )

  func bindingOf(s: PmtestStatusResponse): PmtestBinding =
    if s.bindings.len == 1:
      result = s.bindings[0]

  func digestHex(b: openArray[byte]): string =
    for x in b:
      result.add(toHex(x, 2).toLowerAscii)

  suite "the Package Manager's shell, hosted (G405, G400; C1)":
    teardown:
      releaseAll()
      leftover()

    test "[PKG-0353] [IMPL-DECISION G405] [IMPL-DECISION G401] Runtime-ready while the fake is starting; the catalog acquired on ready and kept; status; resolve of an exact root; no catalog, archive, trust or lcn.pm_input bytes in a carrier frame":
      let input = pmInputBytes()
      let cfg = hosted(input)
      cfg.stock()
      let pmDir = cfg.stateDir("p")
      # [plan §6] Markers: a slice of the catalog, of each archive, of the trust input and of
      # the protected input.
      traceMarkers(
        @[
          document[^32 .. ^1],
          app100[app100.len div 2 ..< app100.len div 2 + 32],
          lib120[lib120.len div 2 ..< lib120.len div 2 + 32],
          orgTrust[^32 .. ^1],
          input[^48 .. ^17],
        ]
      )
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      # The fake is `starting`: the Package Manager is ready all the same.
      check e.started(pmRecord(), "pm").state == msReady
      check not fileExists(pmDir / ".lcn-protected-input")
      let (_, rc) = e.startClient("c")
      driver = rc.open(fakeRoot, fakeSchema)
      probe = rc.open(pmRoot, pmSchema)
      check waitUntil(
        proc(): bool =
          let b = status().bindingOf
          b.state.kind == PmtestBindingStateChoiceKind.Ready and b.readiness.isSome,
        Answer,
      )
      let before = status()
      check before.catalog.isNone
      check before.bindingOf.readiness.get.kind ==
        PmtestBindingReadinessChoiceKind.Starting
      check before.bindingOf.established == 1
      check resolved("app", "1.0.0").errorOf == "package-unavailable"
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check acquired()
      let now = status()
      check now.catalog.get.entries == 2
      check now.catalog.get.digest == @(blake3(document))
      check fileExists(pmDir / KeptName)
      let r = resolved("app", "1.0.0")
      check r.packagesOf == @["app@1.0.0", "lib@1.2.0"]
      check resolved("app", "9.9.9").errorOf.len > 0
      check status().pending == 0
      let (frames, hits) = traced()
      check frames > 0
      check hits == 0
      traceMarkers([])
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G401] a restart with the fake offline uses the kept catalog; a restart in the same run gets a working route, not its previous realization's record (F3)":
      let cfg = hosted(pmInputBytes())
      cfg.stock()
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      discard e.started(pmRecord(), "pm")
      let (_, rc) = e.startClient("c")
      driver = rc.open(fakeRoot, fakeSchema)
      probe = rc.open(pmRoot, pmSchema)
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check acquired()
      let firstRoute = status().bindingOf.route
      check firstRoute.isSome
      # Stopped and started again in this run, with the fake offline.
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Offline)
      probe.release()
      probe = LogosRouteHandle()
      check e.stop("pm").isOk
      check waitUntil(
        proc(): bool =
          e.view("pm").tryGet.state == msUnloaded
      )
      check e.start("pm").tryGet.state == msReady
      probe = rc.open(pmRoot, pmSchema)
      let s = status()
      check s.catalog.isSome # the kept one, at once
      check waitUntil(
        proc(): bool =
          let b = status().bindingOf
          b.state.kind == PmtestBindingStateChoiceKind.Ready and b.readiness.isSome and
            b.readiness.get.kind == PmtestBindingReadinessChoiceKind.Offline,
        Answer,
      )
      let b = status().bindingOf
      check b.route.isSome and b.route != firstRoute
      check b.established == 1 # this realization's first route
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check waitUntil(
        proc(): bool =
          resolved("app", "1.0.0").packagesOf == @["app@1.0.0", "lib@1.2.0"],
        Answer,
      )
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G402] a lost route: the fake's instance is stopped and started again, and the next read succeeds over a new route under a new key":
      let cfg = hosted(pmInputBytes())
      cfg.stock()
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      discard e.started(pmRecord(), "pm")
      let (_, rc) = e.startClient("c")
      driver = rc.open(fakeRoot, fakeSchema)
      probe = rc.open(pmRoot, pmSchema)
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check acquired()
      let firstRoute = status().bindingOf.route
      driver.release()
      driver = LogosRouteHandle()
      check e.stop("hf").isOk
      check waitUntil(
        proc(): bool =
          e.view("hf").tryGet.state == msUnloaded
      )
      check e.start("hf").tryGet.state == msReady
      driver = rc.open(fakeRoot, fakeSchema)
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check waitUntil(
        proc(): bool =
          resolved("app", "1.0.0").packagesOf == @["app@1.0.0", "lib@1.2.0"],
        Answer,
      )
      let b = status().bindingOf
      checkpoint "binding: " & $b
      check b.route.isSome and b.route != firstRoute
      check b.established >= 2
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G395] the fake refuses a fetch-fake/state/ name outside its bound as invalid-locator (F4)":
      let cfg = hosted(pmInputBytes())
      cfg.stock()
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      let (_, rc) = e.startClient("c")
      driver = rc.open(fakeRoot, fakeSchema)
      fetch = rc.open(
        LcnStorageFetchRoot,
        encodeCbor(
          schemaResponse(acceptContractSet(contractDoc).tryGet, LcnStorageFetchRoot).tryGet
        ),
      )
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      proc kindOf(name: string): string =
        let r = invoke(
          addr fetch, LcnNSStorageFetchStatObjectRequest(`object`: stateLocator(name))
        )
        if r.isErr:
          return "error " & $r.error.code
        if r.get.kind == LcnNSStorageFetchStatObjectResponseKind.Map_size:
          return "size " & $r.get.arm_Map_size.size
        $r.get.arm_Map_failure.failure.code.kind

      check kindOf("catalog") == "size " & $document.len
      check kindOf("missing") == "Unavailable"
      for bad in ["..", ".", "a/b", ".hidden", "", "x".repeat(65), "sp ace", "a\\b"]:
        checkpoint bad
        check kindOf(bad) == "Invalid_locator"
      check kindOf("x".repeat(64)) == "Unavailable"
      releaseAll()
      e.finish()

    test "[PKG-0093] [IMPL-DECISION G400] a trust input that selects a profile fails initialization":
      var t = trustOf([anchorOf("org", ["app", "lib"], orgPub)])
      t.catalog = LcnTrustSelection(selected: Opt.some("logos.catalog-signing.x"))
      let cfg = hosted(pmInputBytes(t.trustBytes))
      cfg.stock()
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      let v = e.create(pmRecord(), "pm").tryGet
      let s = e.start(v.instance)
      check s.isErr or s.get.state != msReady
      let after = e.view("pm").tryGet
      check after.state != msReady
      check after.failure.isSome
      if after.failure.isSome:
        # The Runtime records `_MODULE_init`'s code only; the field is named in the
        # operator's log (the next test).
        check after.failure.get.reason == "_MODULE_init() failed with MODULE_ERROR"
      check not fileExists(cfg.stateRoot.get / "p" / ".lcn-protected-input")
      releaseAll()
      e.finish()

    test "[PKG-0093] [IMPL] a refused input is in the operator's log, naming the field":
      var t = trustOf([anchorOf("org", ["app", "lib"], orgPub)])
      t.catalog = LcnTrustSelection(selected: Opt.some("logos.catalog-signing.x"))
      let dir = work / "refused"
      removeDir(dir)
      createDir(dir)
      writeProtectedInput(dir, pmInputBytes(t.trustBytes)).tryGet
      logged.setLen(0)
      # The refusal comes before the shell touches its services.
      let r = openShell(ModuleInit(stateDir: Opt.some(dir)), log = capture)
      check r.isErr
      check logged.len == 1
      if logged.len == 1:
        check logged[0].startsWith(
          "package-manager: initialization failed: lcn.pm_input is refused: trust: "
        )
