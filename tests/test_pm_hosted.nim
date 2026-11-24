## The Package Manager's shell hosted (Tier 5 step 5-3b-2; DECISIONS G405, G400, G401, G402;
## docs/PACKAGE-MANAGER.md §5): `pmtest_module` (`tests/kit/pmtest_impl.nim`, the shell under a
## test name) and the reference fake (`fetch_fake_module`) both realized `hosted_dynamic` under a
## test Runtime. The fake serves a catalog and signed archives from its state directory
## (`fetch-fake/state/<name>`, Q1 (c)); the Package Manager gets its `lcn.pm_input` as its
## protected realization input (G400); the test's client drives the fake and asks the probe.

import std/[atomics, monotimes, os, sequtils, strutils, tables, times, typedthreads]
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
  import std/random
  import ./support/[lgxbuild, modulehostbuild, pmfixture, sanitizerenv, shortdir]
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

  # [G455] The sliced case's catalog: `scan` requires `a1` to `a8` and `gap ^2.0.0`; `a1` to `a7`
  # require `gap ^2.0.0` too and `a8` requires `gap ^3.0.0`. `gap` is listed at `GapVersions`
  # versions 2.x.y, none stocked or retrieved. So once the `a` names are bound, each `gap` version
  # is tested against nine requirements, the last failing, with nothing retrieved: nine turns for
  # each catalog entry, against the one step for each entry that every operation's setup takes.
  # Then the operation fails `dependency-unavailable`.
  const
    ANames = 8
    GapVersions = 10_000
  let
    scan100 = block:
      var deps: seq[(string, string)]
      for i in 1 .. ANames:
        deps.add(("a" & $i, "1.0.0"))
      deps.add(("gap", "2.0.0"))
      packed(dataManifest("scan", "1.0.0", deps, Hosts), "org", orgKey)
    aArchives = block:
      var all: seq[(string, seq[byte])]
      for i in 1 .. ANames:
        let wants = if i == ANames: "3.0.0" else: "2.0.0"
        all.add(
          (
            "a" & $i & "-1.0.0",
            packed(
              dataManifest("a" & $i, "1.0.0", [("gap", wants)], Hosts), "org", orgKey
            ),
          )
        )
      all
    scanTrust = block:
      var names: seq[string]
      for i in 1 .. ANames:
        names.add("a" & $i)
      names.add(["app", "gap", "lib", "scan"])
      trustOf([anchorOf("org", names, orgPub)]).trustBytes
    scanObjects = objects & @[("scan-1.0.0", scan100)] & aArchives
    scanDocument = block:
      var all = entries
      all.add(entryOf("scan", "1.0.0", locator = "fetch-fake/state/scan-1.0.0"))
      for (name, _) in aArchives:
        all.add(entryOf(name[0 .. 1], "1.0.0", locator = "fetch-fake/state/" & name))
      for i in 0 ..< GapVersions:
        all.add(
          entryOf(
            "gap",
            "2." & $(i div 100) & "." & $(i mod 100),
            locator = "fetch-fake/state/gap-" & $i,
          )
        )
      catalogBytes(all)
    # What the fake still serves while it is not ready: every archive the case retrieves, and
    # with `scanGate` every one but the last `a`'s, at which the operation then waits.
    scanHeld = scanObjects.mapIt(pmfixture.bytesOf("fetch-fake/state/" & it[0]))
    scanGate = scanObjects.filterIt(it[0] != "a" & $ANames & "-1.0.0").mapIt(
        pmfixture.bytesOf("fetch-fake/state/" & it[0])
      )

  # [5-5-4] The installation cases' catalog: `app` and `lib` as above, `logos.example` (a module
  # package with a variant for each host), and `big`, the same with a 16 MiB data file in this
  # host's variant. Its bytes are random, so the archive holds them at about their size and the
  # bounds scaled from the archive's size (G453) admit it. `big`'s extraction is slowed by the
  # test hook `LCN_TEST_EXTRACT_PACE_MS` (`pm/store.nim`), a pause for each MiB written.
  const
    hostVariant =
      (when defined(macosx): "darwin-" else: "linux-") &
      (when defined(arm64): "aarch64" else: "x86_64")
    BigBytes = 16 shl 20
  let
    example = modulePackage(allHosts = true).packed("org", orgKey)
    big = block:
      var data = newSeq[byte](BigBytes)
      var g = initRand(5)
      for b in data.mitems:
        b = byte(g.rand(255))
      modulePackage("big", allHosts = true)
        .withFiles(hostVariant, [("data/big.bin", data)])
        .packed("org", orgKey)
    installTrust = trustOf(
      [anchorOf("org", ["app", "big", "lib", "logos.example"], orgPub)]
    ).trustBytes
    installObjects = objects & @[("logos.example-1.0.0", example), ("big-1.0.0", big)]
    installDocument = catalogBytes(
      entries &
        @[
          entryOf(
            "logos.example", "1.0.0", locator = "fetch-fake/state/logos.example-1.0.0"
          ),
          entryOf("big", "1.0.0", locator = "fetch-fake/state/big-1.0.0"),
        ]
    )

  proc pmInputBytes(
      trust = orgTrust, doc = document, limits = Opt.none(LcnPmLimits)
  ): seq[byte] =
    pmValue(
      trust,
      doc,
      bindings = [("main", "hf")],
      limits = limits,
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

  proc stock(cfg: EngineConfig, doc = document, stocked = objects) =
    ## The fake's `objects/`: the catalog and the archives, written before the start.
    let dir = cfg.stateDir("f") / "objects"
    createDir(dir)
    writeFile(dir / "catalog", textOf(doc))
    for (name, bytes) in stocked:
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
  var driver, fetch, probe, probeA: LogosRouteHandle
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
    for h in [addr driver, addr fetch, addr probe, addr probeA]:
      if h[].vtable != nil:
        h[].release()
      h[] = LogosRouteHandle()

  proc drive(
      to: FetchFakeSetReadinessRequestReadinessChoiceKind, held: seq[seq[byte]] = @[]
  ): bool =
    let r = invoke(
      addr driver,
      FetchFakeSetReadinessRequest(
        readiness: FetchFakeSetReadinessRequestReadinessChoice(kind: to), held: held
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

  # [G455] The sliced case's operation, invoked from a thread of its own through `probeA`:
  # 0 while it runs, then 1 for `dependency-unavailable`, 2 for another answer, 3 for an
  # invocation failure.
  var aAnswer: Atomic[int]

  proc resolveScan() {.thread.} =
    {.gcsafe.}:
      let r = invoke(addr probeA, PmtestResolveRequest(name: "scan", version: "1.0.0"))
      aAnswer.store(
        if r.isErr:
          3
        elif r.get.kind == PmtestResolveResponseKind.Map_error and
          r.get.arm_Map_error.error == "dependency-unavailable":
          1
        else:
          2
      )

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

  # [5-5-4] The operations through the probe: each response is one CBOR value in `response`.
  func codeOf(v: CborValue): string =
    ## The response's `package_error` code; empty for a success.
    let e = v.lookup("error")
    if e.isSome:
      let c = e.get.lookup("code")
      if c.isSome:
        return c.get.getText.get("")

  func identityOf(v: CborValue): string =
    ## `{installed: record}`'s identity, as `package@version`.
    let r = v.lookup("installed")
    if r.isSome:
      let id = r.get.lookup("identity")
      if id.isSome:
        return
          id.get.lookup("package").get(cbor("")).getText.get("") & "@" &
          id.get.lookup("version").get(cbor("")).getText.get("")

  proc answerOf(r: auto): CborValue =
    result = cborMap()
    check r.isOk
    if r.isOk:
      let v = decodeCbor(r.get.response)
      check v.isOk
      if v.isOk:
        result = v.get

  proc installed(name, version: string): CborValue =
    answerOf(
      invoke(
        addr probe, PmtestInstallRequest(package: name, version: Opt.some(version))
      )
    )

  proc removed(name, version: string): CborValue =
    answerOf(invoke(addr probe, PmtestRemoveRequest(package: name, version: version)))

  proc handedOff(name, version, module: string): CborValue =
    answerOf(
      invoke(
        addr probe,
        PmtestHandoffRequest(package: name, version: version, module: module),
      )
    )

  # [5-5-4] The long install, invoked from a thread of its own through `probeA`: 0 while it
  # runs, then 1 for `{installed}`, 2 for `package-unavailable`, 3 for another answer, 4 for an
  # invocation failure.
  var bAnswer: Atomic[int]

  proc installBig() {.thread.} =
    {.gcsafe.}:
      let r = invoke(
        addr probeA, PmtestInstallRequest(package: "big", version: Opt.some("1.0.0"))
      )
      var code = 4
      if r.isOk:
        let v = decodeCbor(r.get.response)
        code =
          if v.isErr:
            3
          elif v.get.lookup("installed").isSome:
            1
          elif v.get.codeOf == "package-unavailable":
            2
          else:
            3
      bAnswer.store(code)

  proc extracting(pmDir: string): bool =
    ## A file of a record being staged exists below `install/r/<rid>/a/`.
    let r = pmDir / "install" / "r"
    if not dirExists(r):
      return false
    for rid in walkDir(r):
      if rid.kind == pcDir and dirExists(rid.path / "a"):
        for f in walkDirRec(rid.path / "a"):
          return true
    false

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

    test "[IMPL-DECISION G455] a sliced resolution goes through the event loop turn by turn: a second operation and a readiness event go through between its turns (F2)":
      # The Package Manager's turns are one work unit each (`tests/kit/pmtest_impl.nim`), so
      # `scan` tests each listed `gap` version against each requirement in a turn of its own,
      # then fails `dependency-unavailable`. Were a turn's continue only posted to the shell's
      # queue, its turns would run back to back in one drain, and neither the second operation
      # nor the readiness event nor a status call would be answered before it ended.
      let cfg = hosted(pmInputBytes(scanTrust, scanDocument))
      cfg.stock(scanDocument, scanObjects)
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      discard e.started(pmRecord(), "pm")
      let (_, rc) = e.startClient("c")
      driver = rc.open(fakeRoot, fakeSchema)
      probe = rc.open(pmRoot, pmSchema)
      probeA = rc.open(pmRoot, pmSchema)
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check acquired()
      check status().catalog.get.entries ==
        uint64(entries.len + 1 + aArchives.len + GapVersions)
      proc readiness(): PmtestBindingReadinessChoiceKind =
        let b = status().bindingOf
        if b.readiness.isSome:
          b.readiness.get.kind
        else:
          PmtestBindingReadinessChoiceKind.Starting

      proc reached(r: PmtestBindingReadinessChoiceKind): bool =
        waitUntil(
          proc(): bool =
            readiness() == r,
          Answer,
        )

      # The gate: not ready, serving every archive but the last `a`'s, so the operation's
      # retrievals end there and its scan starts only once the fake is ready again. No status
      # call or other operation can then fall between its retrievals.
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Offline, scanGate)
      check reached(PmtestBindingReadinessChoiceKind.Offline)
      aAnswer.store(0)
      var t: Thread[void]
      createThread(t, resolveScan)
      check waitUntil(
        proc(): bool =
          status().pending == 1,
        Answer,
      )
      # [IMPL] Time for the retrievals the gate lets through. A shorter wait leaves the
      # outcome as it is: the operation cannot end at the gate.
      sleep(3_000)
      check aAnswer.load == 0
      let began = getMonoTime()
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check reached(PmtestBindingReadinessChoiceKind.Ready)
      # A second operation, its retrieval and its own turns.
      check resolved("lib", "1.2.0").packagesOf == @["lib@1.2.0"]
      let second = getMonoTime() - began
      check aAnswer.load == 0
      # A readiness event, from the fake through the Runtime; the fake still serves the case's
      # archives.
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Offline, scanHeld)
      check reached(PmtestBindingReadinessChoiceKind.Offline)
      let during = status()
      let event = getMonoTime() - began
      check aAnswer.load == 0
      check during.pending == 1
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      joinThread(t)
      let took = getMonoTime() - began
      checkpoint "second operation at " & $second & ", readiness at " & $event &
        ", the sliced one ended at " & $took
      check aAnswer.load == 1
      check status().pending == 0
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G449] install over a hosted instance with the fake provider, the dependency first; installed again, the record as it is; a handoff through the probe; a remove refused while depended on; the records kept across the instance's restart":
      let cfg = hosted(pmInputBytes(installTrust, installDocument))
      cfg.stock(installDocument, installObjects)
      let pmDir = cfg.stateDir("p")
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      discard e.started(pmRecord(), "pm")
      let (_, rc) = e.startClient("c")
      driver = rc.open(fakeRoot, fakeSchema)
      probe = rc.open(pmRoot, pmSchema)
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check acquired()
      check installed("app", "1.0.0").identityOf == "app@1.0.0"
      check installed("logos.example", "1.0.0").identityOf == "logos.example@1.0.0"
      check toSeq(walkDir(pmDir / "install" / "r")).len == 3
      check installed("app", "1.0.0").identityOf == "app@1.0.0"
      let h = handedOff("logos.example", "1.0.0", "alpha_module")
      check h.codeOf == ""
      check h.lookup("handoff").isSome
      check handedOff("logos.example", "1.0.0", "no_such_module").codeOf ==
        "invalid-request"
      check removed("lib", "1.2.0").codeOf == "package-in-use"
      check removed("app", "1.0.0").codeOf == ""
      # Stopped and started again: the start reads the records back from the index.
      probe.release()
      probe = LogosRouteHandle()
      check e.stop("pm").isOk
      check waitUntil(
        proc(): bool =
          e.view("pm").tryGet.state == msUnloaded
      )
      check e.start("pm").tryGet.state == msReady
      probe = rc.open(pmRoot, pmSchema)
      check handedOff("logos.example", "1.0.0", "alpha_module").lookup("handoff").isSome
      check handedOff("app", "1.0.0", "alpha_module").codeOf == "package-not-installed"
      # An absent identity's remove succeeds with `{}` (PM §15).
      check removed("app", "1.0.0").codeOf == ""
      check removed("lib", "1.2.0").codeOf == ""
      # The removed records' directories are collected after the commits that retired them.
      check waitUntil(
        proc(): bool =
          toSeq(walkDir(pmDir / "install" / "r")).len == 1,
        Answer,
      )
      check status().pending == 0
      releaseAll()
      e.finish()

    type Long = object
      e: Engine
      pmDir: string
      rc: ptr LogosRuntimeControlBinding
      firstRoute: typeof(PmtestBinding().route)

    proc longSetup(limits = Opt.none(LcnPmLimits)): Long =
      ## [5-5-4] The installation case's instances, `big`'s extraction paced at 1.5 s for
      ## each MiB (about 24 s in all) by the hook the Module Host's environment passes.
      var cfg = hosted(pmInputBytes(installTrust, installDocument, limits))
      cfg.moduleHostEnv.add("LCN_TEST_EXTRACT_PACE_MS")
      cfg.stock(installDocument, installObjects)
      result.pmDir = cfg.stateDir("p")
      result.e = fixtureEngine(cfg)
      discard result.e.started(fakeRecord(), "hf")
      discard result.e.started(pmRecord(), "pm")
      result.rc = result.e.startClient("c")[1]
      driver = result.rc.open(fakeRoot, fakeSchema)
      probe = result.rc.open(pmRoot, pmSchema)
      probeA = result.rc.open(pmRoot, pmSchema)
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check acquired()
      result.firstRoute = status().bindingOf.route
      check result.firstRoute.isSome
      bAnswer.store(0)

    proc stopTimed(e: Engine): Duration =
      ## `pm` stopped, from the request to `unloaded`.
      probe.release()
      probe = LogosRouteHandle()
      let at = getMonoTime()
      check e.stop("pm").isOk
      check waitUntil(
        proc(): bool =
          e.view("pm").tryGet.state == msUnloaded,
        Answer,
      )
      getMonoTime() - at

    test "[IMPL-DECISION G449] during a long extraction the module thread answers: a second operation and a route renewal go through; a stop with the install's call in flight cancels it and ends inside the stop deadline (W2), its directory deleted":
      # Were the extraction not stopped, it would run about 24 s, past the 10 s stop
      # deadline. The stop ends the route, and the Runtime's cancel reaches the handler
      # through the kit's `request_cancel` (G338); the operation is cancelled, the call
      # ends, `_MODULE_destroy` comes, and the worker stops at its next piece.
      putEnv("LCN_TEST_EXTRACT_PACE_MS", "1500")
      defer:
        delEnv("LCN_TEST_EXTRACT_PACE_MS")
      let l = longSetup()
      let (e, pmDir, rc) = (l.e, l.pmDir, l.rc)
      var t: Thread[void]
      createThread(t, installBig)
      check waitUntil(
        proc(): bool =
          extracting(pmDir),
        Answer,
      )
      let began = getMonoTime()
      # A second operation, answered on the module thread: no version 9.9.9 is listed, so it
      # needs no file work.
      check resolved("app", "9.9.9").errorOf.len > 0
      # A route renewal: the fake's instance is stopped and started again (G402), and the
      # binding gets a new route, watched for readiness.
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
          let b = status().bindingOf
          b.route.isSome and b.route != l.firstRoute and b.readiness.isSome and
            b.readiness.get.kind == PmtestBindingReadinessChoiceKind.Ready,
        Answer,
      )
      checkpoint "the operation and the renewal took " & $(getMonoTime() - began)
      check bAnswer.load == 0
      check extracting(pmDir)
      let stopped = e.stopTimed()
      joinThread(t)
      checkpoint "the stop took " & $stopped & "; the install's answer " & $bAnswer.load
      check stopped < initDuration(seconds = 5)
      check e.view("pm").tryGet.failure.isNone
      # The route failed under the call: an invocation failure, not a response.
      check bAnswer.load == 4
      check not extracting(pmDir)
      check e.start("pm").tryGet.state == msReady
      probe = rc.open(pmRoot, pmSchema)
      check handedOff("big", "1.0.0", "alpha_module").codeOf == "package-not-installed"
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G449] an operation's deadline answers its call while the worker extracts; a stop then ends at the worker's next piece (W2), its directory deleted":
      # No job is cancelled when an operation ends (G449's limit): the worker goes on
      # extracting for nobody until the destroy sets its stop flag.
      putEnv("LCN_TEST_EXTRACT_PACE_MS", "1500")
      defer:
        delEnv("LCN_TEST_EXTRACT_PACE_MS")
      let l =
        longSetup(Opt.some(LcnPmLimits(operation_deadline_ms: Opt.some(8_000'u32))))
      let (e, pmDir) = (l.e, l.pmDir)
      var t: Thread[void]
      createThread(t, installBig)
      check waitUntil(
        proc(): bool =
          extracting(pmDir),
        Answer,
      )
      joinThread(t)
      check bAnswer.load == 2
      check extracting(pmDir)
      let stopped = e.stopTimed()
      checkpoint "the stop took " & $stopped
      check stopped < initDuration(seconds = 5)
      check e.view("pm").tryGet.failure.isNone
      check not extracting(pmDir)
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
