## The Package Manager module hosted (Tier 5 step 5-6a-1; DECISIONS G490, G491, G494, G495,
## G496; docs/PACKAGE-MANAGER.md §6): `liblogos_package_manager` (`src/logos_package_manager.nim`,
## the facade over the shell) realized `hosted_dynamic` under a test Runtime whose configuration
## marks it (`EngineConfig.packageManager`, G490), with the reference fake (`fetch_fake_module`)
## as its storage, as `test_pm_hosted` hosts the shell's probe. Every call crosses the Module
## Host's boundary: through a route the Runtime materializes, or as a transport consumer
## (`trnowner`) where a case cancels a call. The operations' cases came from `test_pm_hosted`
## (G496: `pmtest` keeps its probe).
##
## The Module Host inherits the test's fd 2 when it is spawned: a case that reads the module's
## operator lines points fd 2 at a file for the start (`startedLogging`).

import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times, typedthreads]
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
import ../src/logos_core/pins as core_pins
import ../src/logos_core/package/records
from ../src/logos_core/pm/requests import sourceOf, identityOf, updateOp
import ../src/logos_core/pm/logos_package_manager_types

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "pm-module" / kitVariant
  cfgTypesDoc = readFile(repo / "spec/mirrors/CFG/9.configuration-types.cddl")
removeDir(work)
createDir(work)

include ./support/routefixture

suite "the Package Manager module's requests (G449, G494)":
  test "[IMPL-DECISION G494] [SPEC PM §6] a typed package_source becomes the engine's source as decodeSource makes it from the same bytes, its refusal included":
    proc lgx(obj: string, prov = Opt.none(string)): CborValue =
      var entries = @[
        (cbor("kind"), cbor("lgx")),
        (cbor("object"), cbor(obj.toOpenArrayByte(0, obj.high))),
        (cbor("storage"), cbor("main")),
      ]
      if prov.isSome:
        entries.add(
          (cbor("provenance_object"), cbor(prov.get.toOpenArrayByte(0, prov.get.high)))
        )
      cborMap(entries)

    let cases = [
      lgx("fetch-fake/state/app-1.0.0"),
      lgx("a", Opt.some("b")),
      lgx("same", Opt.some("same")), # refused: provenance_object equals object
      cborMap((cbor("flake_ref"), cbor("github:o/r")), (cbor("kind"), cbor("nix"))),
      cborMap(
        (cbor("attr"), cbor("packages.x")),
        (cbor("flake_ref"), cbor("github:o/r")),
        (cbor("kind"), cbor("nix")),
        (cbor("locked_ref"), cbor("github:o/r/abc")),
      ),
    ]
    for v in cases:
      let bytes = encodeCbor(v)
      checkpoint toDiag(v)
      let typed = LogosNSPackageManagerPackageSource.decode(bytes)
      check typed.isOk
      let mine = sourceOf(typed.get)
      let theirs = decodeSource(v)
      check mine.isOk == theirs.isOk
      if mine.isOk and theirs.isOk:
        check mine.get == theirs.get
      elif mine.isErr and theirs.isErr:
        check mine.error == theirs.error

  test "[IMPL-DECISION G449] [SPEC PM §15 l.1701-1707] update_package: the root is current's package, newer than current, at the target version when one is given":
    let r = LogosNSPackageManagerUpdatePackageRequest(
      current: LogosNSPackageManagerPackageIdentity(package: "lib", version: "1.0.0"),
      target_version: Opt.some("1.2.0"),
    )
    let op = updateOp(r)
    check op.isOk
    check op.get.root.package == Opt.some("lib")
    check op.get.root.version == Opt.some("1.2.0")
    check op.get.root.newerThan == Opt.some(identityOf(r.current))
    check op.get.root.source.isNone

when defined(posix):
  import logos_sdk/crypto/blake3
  import std/random
  import std/posix except Time
  import
    ./support/[lgxbuild, modulehostbuild, pmbuild, pmfixture, sanitizerenv, shortdir]
  import ../src/logos_core/pm/input_types
  import ./support/trnowner except Provider, now, binding, issue, live, release, gate
  from ./support/pmreply import inspectedBytes
  from logos_sdk/testing/generated/fetch_fake_module_calls import
    invoke, FetchFakeSetReadinessRequest, FetchFakeSetReadinessRequestReadinessChoice,
    FetchFakeSetReadinessRequestReadinessChoiceKind

  const
    Answer = 60 * Slow ## seconds: bounds a wait for the Package Manager
    Wait = 1000 * Answer ## ms
    PmModule = "logos_package_manager"

  let
    hostProgram = moduleHostProgram()
    fakeLib = buildKitLibrary("fetch_fake_impl.nim", "pmmfake")
    rawLib = buildKitLibrary("rawreply_impl.nim", "pmmraw")
    pmLib = pmLibrary()
    shortBase = makeShortBase("lcnpmm", "/e999/12345678/logos_fetch_fake_module.sock")
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
    rawSet = acceptContractSet(readFile(repo / "tests/kit/rawreply_module.cddl")).tryGet
    rawRoot = rawSet.primary.root
    rawSchema = encodeCbor(schemaResponse(rawSet, rawRoot).tryGet)

  proc digestOf(path: string): array[32, byte] =
    let bytes = readFile(path)
    blake3(bytes.toOpenArrayByte(0, bytes.high))

  let
    fakeDigest = digestOf(fakeLib)
    rawDigest = digestOf(rawLib)
    pmDigest = digestOf(pmLib)

  # The packages, as `test_pm_hosted`'s installation cases have them: signed once (each
  # signature takes about a second), with a variant for each host the suite runs on. `big`
  # holds a 16 MiB random data file in this host's variant; its extraction is slowed by the
  # test hook `LCN_TEST_EXTRACT_PACE_MS` (`pm/store.nim`), a pause for each MiB written.
  const
    Hosts = [
      ("linux-x86_64", "linux", "x86_64"),
      ("linux-aarch64", "linux", "aarch64"),
      ("darwin-aarch64", "darwin", "aarch64"),
      ("darwin-x86_64", "darwin", "x86_64"),
    ]
    hostVariant =
      (when defined(macosx): "darwin-" else: "linux-") &
      (when defined(arm64): "aarch64" else: "x86_64")
    BigBytes = 16 shl 20
  let
    (orgKey, orgPub) = testKey(1)
    app100 =
      packed(dataManifest("app", "1.0.0", [("lib", "1.0.0")], Hosts), "org", orgKey)
    lib120 = packed(dataManifest("lib", "1.2.0", variants = Hosts), "org", orgKey)
    example = modulePackage(allHosts = true).packed("org", orgKey)
    big = block:
      var data = newSeq[byte](BigBytes)
      var g = initRand(5)
      for b in data.mitems:
        b = byte(g.rand(255))
      modulePackage("big", allHosts = true)
        .withFiles(hostVariant, [("data/big.bin", data)])
        .packed("org", orgKey)
    trust = trustOf([anchorOf("org", ["app", "big", "lib", "logos.example"], orgPub)]).trustBytes
    objects = @[
      ("app-1.0.0", app100),
      ("lib-1.2.0", lib120),
      ("logos.example-1.0.0", example),
      ("big-1.0.0", big),
    ]
    document = catalogBytes(
      @[
        entryOf("app", "1.0.0", locator = "fetch-fake/state/app-1.0.0"),
        entryOf("lib", "1.2.0", locator = "fetch-fake/state/lib-1.2.0"),
        entryOf(
          "logos.example", "1.0.0", locator = "fetch-fake/state/logos.example-1.0.0"
        ),
        entryOf("big", "1.0.0", locator = "fetch-fake/state/big-1.0.0"),
      ]
    )

  proc pmInputBytes(limits = Opt.none(LcnPmLimits)): seq[byte] =
    pmValue(
      trust,
      document,
      bindings = [("main", "hf")],
      limits = limits,
      catalogLocator = "fetch-fake/state/catalog",
    ).encode.tryGet

  proc hosted(input = pmInputBytes(), mark = true): EngineConfig =
    ## `config` with a state root, the Module Host program, a short endpoint directory and
    ## the Package Manager's protected input; with `mark`, `pm` is the marked instance
    ## (G490).
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
    if mark:
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

  proc rawRecord(): ModuleRecord =
    ModuleRecord(
      module: "rawreply_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "rawreply", localPath: rawLib, hash: rawDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(rawRoot),
    )

  proc startedLogging(
      e: Engine, r: ModuleRecord, instance, path: string
  ): InstanceView =
    ## `instance` started with its Module Host's fd 2 on `path`: a host inherits fd 2 when
    ## it is spawned, and the test's own fd 2 comes back once the start returned.
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

  # The client's handles: the fake's driver, two routes to the Package Manager, one to the
  # raw-reply fixture. Each is a route of its own, so a hosted provider's ticket is used once
  # (G258).
  var driver, pm, pmA, rawH: LogosRouteHandle
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
    for h in [addr driver, addr pm, addr pmA, addr rawH]:
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

  func identity(package, version: string): CborValue =
    cborMap((cbor("package"), cbor(package)), (cbor("version"), cbor(version)))

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

  func installedOf(v: CborValue): string =
    ## `{installed: record}`'s identity, as `package@version`.
    let r = v.lookup("installed")
    if r.isSome:
      let id = r.get.lookup("identity")
      if id.isSome:
        return
          id.get.lookup("package").get(cbor("")).getText.get("") & "@" &
          id.get.lookup("version").get(cbor("")).getText.get("")

  proc inspected(package, version: string): RcResult =
    pm.call("inspect_package", rootRequest(package, version))

  proc acquired(): bool =
    ## The catalog is in use: `app`'s inspection succeeds.
    waitUntil(
      proc(): bool =
        let r = inspected("app", "1.0.0")
        r.code == ecOk and decodeCbor(r.response).isOk and
          decodeCbor(r.response).get.lookup("inspection").isSome,
      Answer,
    )

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

  proc pmRoute(rc: ptr LogosRuntimeControlBinding): Opt[string] =
    ## The Package Manager's ready route, as Runtime Control lists it: no call to the
    ## module, so it is answered while the module's worker extracts.
    let r =
      rcCall(rc, "list_routes", encode(LogosNSRuntimeControlListRoutesRequest()).tryGet)
    if r.code != ecOk:
      return Opt.none(string)
    for rt in LogosNSRuntimeControlListRoutesResponse.decode(r.response).tryGet.routes:
      if rt.consumer.module_instance_id == "pm" and
          rt.state.kind == LogosNSRuntimeControlRouteStateKind.Ready:
        return Opt.some(rt.route)
    Opt.none(string)

  type Setup = object
    e: Engine
    pmDir, log: string
    rc: ptr LogosRuntimeControlBinding

  proc setup(cfg: EngineConfig, name: string): Setup =
    ## The fake and the marked Package Manager started, the fake ready, the catalog in use;
    ## the module's operator lines go to `<work>/<name>.log`.
    cfg.stock()
    result.pmDir = cfg.stateDir("p")
    result.log = work / (name & ".log")
    removeFile(result.log)
    result.e = fixtureEngine(cfg)
    discard result.e.started(fakeRecord(), "hf")
    discard result.e.startedLogging(pmRecord(), "pm", result.log)
    result.rc = result.e.startClient("c")[1]
    driver = result.rc.open(fakeRoot, fakeSchema)
    pm = result.rc.open(pmRoot, pmSchema)
    check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
    check acquired()

  proc stopTimed(e: Engine): Duration =
    ## `pm` stopped, from the request to `unloaded`.
    pm.release()
    pm = LogosRouteHandle()
    let at = getMonoTime()
    check e.stop("pm").isOk
    check waitUntil(
      proc(): bool =
        e.view("pm").tryGet.state == msUnloaded,
      Answer,
    )
    getMonoTime() - at

  # [5-5-4] The long install, invoked from a thread of its own through `pmA`: -1 while it
  # runs, then 0 for `{installed}`, 1 for `package-unavailable`, 2 for another answer, and
  # 100 + the code for an invocation failure.
  var bAnswer: Atomic[int]

  proc installBig() {.thread.} =
    {.gcsafe.}:
      let r = pmA.call("install_package", rootRequest("big", "1.0.0"))
      var code = 2
      if r.code != ecOk:
        code = 100 + ord(r.code)
      else:
        let v = decodeCbor(r.response)
        if v.isOk and v.get.lookup("installed").isSome:
          code = 0
        elif v.isOk and v.get.codeOf == "package-unavailable":
          code = 1
      bAnswer.store(code)

  # The transport consumer, for the cases that cancel a call --------------------------------

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

  proc failureOf(o: Opt[CallOutcome]): Opt[InvocationFailure] =
    if o.isSome and not o.get.ok:
      Opt.some(o.get.failure)
    else:
      Opt.none(InvocationFailure)

  suite "the Package Manager module, hosted (G490, G491, G494, G495; C1)":
    teardown:
      releaseAll()
      leftover()

    test "[PKG-0003] [IMPL-DECISION G490] a hosted logos_package_manager starts only as the marked instance: unmarked it is refused, marked it is ready":
      let cfg = hosted(mark = false)
      cfg.stock()
      discard cfg.stateDir("p")
      let e = fixtureEngine(cfg)
      discard e.started(fakeRecord(), "hf")
      let v = e.create(pmRecord(), "pm").tryGet
      let s = e.start(v.instance)
      check s.isErr or s.get.state != msReady
      let after = e.view("pm").tryGet
      check after.state != msReady
      check after.failure.isSome
      if after.failure.isSome:
        checkpoint after.failure.get.reason
      e.finish()
      let marked = hosted()
      marked.stock()
      discard marked.stateDir("p")
      let m = fixtureEngine(marked)
      discard m.started(fakeRecord(), "hf")
      check m.started(pmRecord(), "pm").state == msReady
      m.finish()

    test "[IMPL-DECISION G494] [PKG-0513] [PKG-0366] [PKG-0367] [PKG-0369] [PKG-0370] [PKG-0371] [PKG-0372] [PKG-0373] [PKG-0374] [PKG-0375] [PKG-0376] [PKG-0377] [PKG-0379] [PKG-0519] [PKG-0521] [PKG-0630] [PKG-0631] [PKG-0633] [PKG-0637] [PKG-0639] [PKG-0640] [PKG-0641] [PKG-0642] [PKG-0643] [PKG-0644] [PKG-0645] [PKG-0646] [PKG-0647] [PKG-0649] the module's contract is the pinned App A, its request and response rules among it; inspect_package's reply is the engine's encoded bytes, unchanged, and its own deterministic encoding":
      # The kit was generated from the pinned documents (`pmContractDocuments`), and the
      # Runtime accepted the module's surface against `pmRoot`, the pinned App A's root.
      let (primary, interfaces, supporting) = pmContractDocuments()
      check primary == core_pins.PackageManagerContractDocument
      check interfaces.len == 0
      check sorted(supporting) ==
        sorted(@[core_pins.PackageManifestDocument, cfgTypesDoc])
      let s = setup(hosted(), "inspect")
      let r = inspected("app", "1.0.0")
      check r.code == ecOk
      check canonical(r.response)
      var served: seq[(string, seq[byte])]
      for (name, bytes) in objects:
        served.add(("fetch-fake/state/" & name, bytes))
      let engineBytes = inspectedBytes(document, trust, served, "app", "1.0.0")
      check r.response == engineBytes
      # `{error}`, encoded by the facade: no version 9.9.9 is listed.
      check inspected("app", "9.9.9").valueOf.codeOf == "package-unavailable"
      releaseAll()
      s.e.finish()

    test "[IMPL-DECISION G449] [IMPL-DECISION G494] the four operations: install with the dependency first, installed again as it is, update and remove refused while depended on, remove, remove of an absent identity; each reply its own deterministic encoding; the records kept across a restart":
      let s = setup(hosted(), "operations")
      let e = s.e
      let first = pm.call("install_package", rootRequest("app", "1.0.0"))
      check first.valueOf.installedOf == "app@1.0.0"
      check pm.call("install_package", rootRequest("logos.example", "1.0.0")).valueOf.installedOf ==
        "logos.example@1.0.0"
      check toSeq(walkDir(s.pmDir / "install" / "r")).len == 3
      # Installed again: the record as it is, the same bytes.
      let again = pm.call("install_package", rootRequest("app", "1.0.0"))
      check again.code == ecOk and again.response == first.response
      # [PKG-0406] update and remove of what another record depends on.
      check pm.call(
        "update_package", cborMap((cbor("current"), identity("lib", "1.2.0")))
      ).valueOf.codeOf == "package-in-use"
      check pm.call(
        "remove_package", cborMap((cbor("identity"), identity("lib", "1.2.0")))
      ).valueOf.codeOf == "package-in-use"
      # `{}`, encoded by the facade.
      let removed =
        pm.call("remove_package", cborMap((cbor("identity"), identity("app", "1.0.0"))))
      check removed.code == ecOk and removed.response == @[0xa0'u8]
      # Stopped and started again: the start reads the records back from the index.
      pm.release()
      pm = LogosRouteHandle()
      check e.stop("pm").isOk
      check waitUntil(
        proc(): bool =
          e.view("pm").tryGet.state == msUnloaded
      )
      check e.start("pm").tryGet.state == msReady
      pm = s.rc.open(pmRoot, pmSchema)
      let kept = inspected("logos.example", "1.0.0").valueOf.lookup("inspection")
      check kept.isSome
      # An absent identity's remove succeeds with `{}` (PM §15).
      check pm.call(
        "remove_package", cborMap((cbor("identity"), identity("app", "1.0.0")))
      ).response == @[0xa0'u8]
      check pm.call(
        "remove_package", cborMap((cbor("identity"), identity("lib", "1.2.0")))
      ).response == @[0xa0'u8]
      releaseAll()
      e.finish()

    test "[PKG-0166] [IMPL-DECISION G494] a request with a key its schema does not have, or a source the schema cannot refuse, is INVALID_PARAMS":
      let s = setup(hosted(), "params")
      let extra = cborMap(
        (cbor("package"), cbor("app")),
        (cbor("version"), cbor("1.0.0")),
        (cbor("zzz"), cbor(1'u64)),
      )
      check pm.call("install_package", extra).code == ecInvalidParams
      check pm.call("inspect_package", extra).code == ecInvalidParams
      let same = @[byte('x')]
      let source = cborMap(
        (cbor("kind"), cbor("lgx")),
        (cbor("object"), cbor(same)),
        (cbor("provenance_object"), cbor(same)),
        (cbor("storage"), cbor("main")),
      )
      let r = pm.call(
        "install_package",
        cborMap((cbor("package"), cbor("app")), (cbor("source"), source)),
      )
      check r.code == ecInvalidParams
      check r.message == "source: provenance_object equals object"
      releaseAll()
      s.e.finish()

    test "[IMPL-DECISION G495] list_packages, list_installed_packages, watch_installed_packages and an ordinary caller's get_runtime_handoff end MODULE_ERROR with no message and no detail; each writes one operator line naming the caller and the method":
      let s = setup(hosted(), "refused")
      let handoff = cborMap(
        (cbor("module"), cbor("alpha_module")),
        (cbor("package"), identity("logos.example", "1.0.0")),
      )
      for (meth, request) in [
        ("list_packages", cborMap()),
        ("list_installed_packages", cborMap()),
        ("watch_installed_packages", cborMap()),
        ("get_runtime_handoff", handoff),
      ]:
        checkpoint meth
        let r = pm.call(meth, request)
        check r.code == ecModule
        check r.message == ""
        check r.detail.len == 0
        check r.response.len == 0
      check waitUntil(
        proc(): bool =
          s.log.linesWith("refused for").len == 4
      )
      for meth in [
        "list_packages", "list_installed_packages", "watch_installed_packages",
        "get_runtime_handoff",
      ]:
        let lines = s.log.linesWith("package-manager: " & meth & " refused for ")
        checkpoint meth & ": " & $lines
        check lines.len == 1
        if lines.len == 1:
          check "refused for module instance c of Runtime " in lines[0]
          check lines[0].endsWith(": not a reader")
      releaseAll()
      s.e.finish()

    test "[IMPL-DECISION G338] [IMPL-DECISION G449] a full mutation queue answers MODULE_ERROR; a consumer's cancel of a queued and of a running install ends each call CANCELLED and the handler logs it":
      putEnv("LCN_TEST_EXTRACT_PACE_MS", "1500")
      defer:
        delEnv("LCN_TEST_EXTRACT_PACE_MS")
      var cfg = hosted()
      cfg.moduleHostEnv.add("LCN_TEST_EXTRACT_PACE_MS")
      let s = setup(cfg, "queue")
      let o = newOwner(fastConfig())
      defer:
        o.stop()
      let conn = o.session(s.rc.directOf())
      let running = o.send(conn, "install_package", rootRequest("big", "1.0.0"))
      check waitUntil(
        proc(): bool =
          extracting(s.pmDir),
        Answer,
      )
      # The mutation slot runs `big`; 16 more wait (`MaxQueuedOperations`), and one more
      # finds the queue full. The 17 calls are concurrent and reach the engine in no set
      # order, so the refused one is whichever came last, not always the last sent.
      var sent: seq[uint64]
      for i in 1 .. 17:
        sent.add(o.send(conn, "install_package", rootRequest("app", "1.0.0")))
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
        let f = o.outcome(conn, answered[0], 0).failureOf
        check f.isSome
        if f.isSome:
          check f.get.code == ecModule
          check f.get.message == Opt.some(
            "the Package Manager's mutation queue is full"
          )
      let queued = sent.filterIt(it notin answered)
      check queued.len == 16
      # Each queued call, then the running one, cancelled by their consumer: the queued
      # ones first, so that none starts once `big` ends.
      proc cancelled(tag: uint64): Opt[ErrorCode] =
        o.cancel(conn, tag)
        o.outcome(conn, tag).failureOf.map(
          proc(x: InvocationFailure): ErrorCode =
            x.code
        )

      for tag in queued:
        let c = cancelled(tag)
        check c == Opt.some(ecCancelled)
      let c = cancelled(running)
      check c == Opt.some(ecCancelled)
      check waitUntil(
        proc(): bool =
          s.log.linesWith("package-manager: install_package cancelled by the Runtime").len ==
            17
      )
      # The worker goes on extracting for nobody (G449's limit) until the stop.
      let stopped = s.e.stopTimed()
      check stopped < initDuration(seconds = 5)
      check not extracting(s.pmDir)
      releaseAll()
      s.e.finish()

    test "[IMPL-DECISION G449] [IMPL-DECISION G402] during a long extraction the module thread answers: a second operation and a route renewal go through; a stop with the install's call in flight: the handler ends, its operation cancelled and one line logged; the caller's call fails; the stop ends inside its deadline, the record's directory deleted":
      # Were the extraction not stopped, it would run about 24 s, past the 10 s stop
      # deadline. The stop cancels the call (G338): the handler's operation is cancelled in
      # the engine, `_MODULE_destroy` comes, and the worker stops at its next piece.
      putEnv("LCN_TEST_EXTRACT_PACE_MS", "1500")
      defer:
        delEnv("LCN_TEST_EXTRACT_PACE_MS")
      var cfg = hosted()
      cfg.moduleHostEnv.add("LCN_TEST_EXTRACT_PACE_MS")
      let s = setup(cfg, "stop")
      pmA = s.rc.open(pmRoot, pmSchema)
      bAnswer.store(-1)
      var t: Thread[void]
      createThread(t, installBig)
      check waitUntil(
        proc(): bool =
          extracting(s.pmDir),
        Answer,
      )
      let began = getMonoTime()
      # A second operation, answered on the module thread: no version 9.9.9 is listed, so
      # it needs no file work.
      check inspected("app", "9.9.9").valueOf.codeOf == "package-unavailable"
      # A route renewal: the fake's instance is stopped and started again (G402), and the
      # binding gets a new route, which Runtime Control lists ready. An operation that
      # fetched over it would wait for the worker, which extracts.
      let firstRoute = s.rc.pmRoute()
      check firstRoute.isSome
      driver.release()
      driver = LogosRouteHandle()
      check s.e.stop("hf").isOk
      check waitUntil(
        proc(): bool =
          s.e.view("hf").tryGet.state == msUnloaded
      )
      check s.e.start("hf").tryGet.state == msReady
      driver = s.rc.open(fakeRoot, fakeSchema)
      check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
      check waitUntil(
        proc(): bool =
          let r = s.rc.pmRoute()
          r.isSome and r != firstRoute,
        Answer,
      )
      checkpoint "the operation and the renewal took " & $(getMonoTime() - began)
      check bAnswer.load == -1
      check extracting(s.pmDir)
      let stopped = s.e.stopTimed()
      joinThread(t)
      checkpoint "the stop took " & $stopped & "; the install's answer " & $bAnswer.load
      check stopped < initDuration(seconds = 5)
      check s.e.view("pm").tryGet.failure.isNone
      check not extracting(s.pmDir)
      # The handler's end: its operation cancelled, one line in the operator's log.
      check s.log.linesWith("package-manager: install_package cancelled by the Runtime").len ==
        1
      # The caller's code, as the boundary gives it: the call failed, it was not answered.
      check bAnswer.load >= 100
      check bAnswer.load - 100 in [ord(ecCancelled), ord(ecNotReady), ord(ecTransport)]
      releaseAll()
      s.e.finish()

    test "[IMPL-DECISION G449] an operation's deadline answers its call while the worker extracts; a stop then ends at the worker's next piece, its directory deleted":
      putEnv("LCN_TEST_EXTRACT_PACE_MS", "1500")
      defer:
        delEnv("LCN_TEST_EXTRACT_PACE_MS")
      var cfg = hosted(
        pmInputBytes(Opt.some(LcnPmLimits(operation_deadline_ms: Opt.some(8_000'u32))))
      )
      cfg.moduleHostEnv.add("LCN_TEST_EXTRACT_PACE_MS")
      let s = setup(cfg, "deadline")
      pmA = s.rc.open(pmRoot, pmSchema)
      bAnswer.store(-1)
      var t: Thread[void]
      createThread(t, installBig)
      check waitUntil(
        proc(): bool =
          extracting(s.pmDir),
        Answer,
      )
      joinThread(t)
      check bAnswer.load == 1
      check extracting(s.pmDir)
      let stopped = s.e.stopTimed()
      checkpoint "the stop took " & $stopped
      check stopped < initDuration(seconds = 5)
      check s.e.view("pm").tryGet.failure.isNone
      check not extracting(s.pmDir)
      releaseAll()
      s.e.finish()

  suite "a pre-encoded response at the Module Host's boundary (G494)":
    teardown:
      releaseAll()
      leftover()

    test "[IMPL-DECISION G494] pre-encoded bytes cross the boundary unchanged; bytes off the method's schema, not deterministic, empty or more than one value are MODULE_ERROR from the boundary":
      let cfg = hosted()
      let e = fixtureEngine(cfg)
      discard e.started(rawRecord(), "raw")
      let (_, rc) = e.startClient("c")
      rawH = rc.open(rawRoot, rawSchema)
      proc sent(bytes: seq[byte]): RcResult =
        rawH.call("reply", cborMap((cbor("bytes"), cbor(bytes))))

      for v in [
        cborMap((cbor("value"), cbor(7'u64))),
        cborMap((cbor("value"), cbor(high(uint64)))),
        cborMap((cbor("error"), cbor("x"))),
      ]:
        let bytes = encodeCbor(v)
        let r = sent(bytes)
        checkpoint toDiag(v)
        check r.code == ecOk
        check r.response == bytes
      let seven = encodeCbor(cborMap((cbor("value"), cbor(7'u64))))
      var wide = @[0xa1'u8, 0x65]
      wide.add("value".toOpenArrayByte(0, 4))
      wide.add([0x18'u8, 0x07]) # 7 in two bytes: not deterministic
      for bad in [
        encodeCbor(cborMap((cbor("value"), cbor("x")))), # off the schema
        encodeCbor(cborMap((cbor("other"), cbor(7'u64)))),
        wide,
        @[], # no value
        seven & seven, # two values
        seven[0 ..^ 2], # cut short
      ]:
        checkpoint $bad
        let r = sent(bad)
        check r.code == ecModule
        check r.response.len == 0
      releaseAll()
      e.finish()
