## logosd with a `package_manager` section (Tier 5 step 5-3b-2; DECISIONS G399, G400, G402,
## G405; docs/DAEMON.md §3 and §5, docs/PACKAGE-MANAGER.md §4). `pmtest_module`
## (`tests/kit/pmtest_impl.nim`, the shell under a test name) is the Package Manager. The
## reference fake (`fetch_fake_module`) is its one storage provider, serving a catalog and signed
## archives from its state directory (`fetch-fake/state/<name>`). Both are `hosted_dynamic`
## operator instances that the orchestrator starts, under `capability-authority`.
##
## The test drives the fake and asks the probe as an operator would, with `logosctl call` through
## `lcn_call` (DAEMON.md §7a); an operator rule grants `lcn_call` both providers. No operator rule
## grants the Package Manager or the fake anything. Its `list_modules` lookup and its route (S9),
## its readiness subscription (S10) and the fake's event (S11) pass on logosd's derived rules
## alone: the catalog is acquired only on the fake's `fetch_readiness_changed`. The package-signing
## trust is the session's trust file, written with `logosctl trust`. A change to it applies at the
## next start.
##
## The children are built for the suite's variant (`daemonbuild.nim`), as in `test_logosd.nim`.
## Every case leaves no Module Host of this build behind.

when defined(posix):
  import std/[json, monotimes, os, strutils, times]
  import unittest2
  import logos_sdk/crypto/blake3
  import ../src/logos_core/daemon/[config, daemon_config_types, session, sessioninit]
  from ../src/logos_core/authority/scopes import sortSet
  from ../src/logos_core/durable import ensurePrivateDir
  from ../src/logos_core/runtime/protinput import ProtectedInputName
  from logos_sdk/iface/accept import acceptContractSet
  from logos_sdk/contracts/generated/lcn_storage_fetch_root import LcnStorageFetchRoot
  import
    ./support/[
      clibuild, daemonbuild, daemonproc, modulehostbuild, pmfixture, sanitizerenv,
      shortdir, slowdown,
    ],
    logos_sdk/testing/kitbuild

  import std/posix

  const
    ReadyMs = 120_000 * Slow
      ## [IMPL] Only bounds a wait for what comes, as in `test_logosd.nim`.
    StopDeadlineMs = 10_000 * Slow
    StopMs = 3 * StopDeadlineMs
    HostsGoneMs = 10_000 * Slow
    FakeInstance = "fetch-1"
    PmInstance = "pm-1"
    FakeState = "fetch-1"
    PmState = "pm-1"
    CatalogName = "catalog"
    Hosts = [
      ("linux-x86_64", "linux", "x86_64"),
      ("linux-aarch64", "linux", "aarch64"),
      ("darwin-aarch64", "darwin", "aarch64"),
      ("darwin-x86_64", "darwin", "x86_64"),
    ]

  let
    repo = currentSourcePath().parentDir.parentDir
    dExe = logosdProgram()
    ctlExe = logosctlProgram()
    hostExe = moduleHostProgram()
    cliArt = cliArtifact()
    fakeLib = buildKitLibrary("fetch_fake_impl.nim", "lpmfake")
    pmLib = buildKitLibrary("pmtest_impl.nim", "lpmpm")
    fakeRoot = @(
      acceptContractSet(
        readFile(repo / "sdk/src/logos_sdk/testing/fixtures/fetch_fake_module.cddl"),
        [readFile(repo / "sdk/src/logos_sdk/contracts/lcn_storage_fetch.cddl")],
      )
      .expect("the fetch_fake_module contract set").primary.root
    )
    pmRoot = @(
      acceptContractSet(readFile(repo / "tests/kit/pmtest_module.cddl"))
      .expect("the pmtest_module contract set").primary.root
    )
    # The packages, signed once (each signature takes about a second).
    (orgKey, orgPub) = testKey(1)
    app100 =
      packed(dataManifest("app", "1.0.0", [("lib", "1.0.0")], Hosts), "org", orgKey)
    lib120 = packed(dataManifest("lib", "1.2.0", variants = Hosts), "org", orgKey)
    objects = @[("app-1.0.0", app100), ("lib-1.2.0", lib120)]
    document = catalogBytes(
      [
        entryOf("app", "1.0.0", locator = "fetch-fake/state/app-1.0.0"),
        entryOf("lib", "1.2.0", locator = "fetch-fake/state/lib-1.2.0"),
      ]
    )

  var cases = 0
  var children: seq[Child]

  func hexOf(bytes: openArray[byte]): string =
    for b in bytes:
      result.add(toHex(b, 2).toLowerAscii)

  proc digestOfFile(path: string): seq[byte] =
    let bytes = readFile(path)
    @(blake3(bytes.toOpenArrayByte(0, bytes.high)))

  type Case = object
    dir: string ## the case's directory: the session is `dir/s`
    s: Session

  proc newCase(): Case =
    inc cases
    result.dir = makeShortBase(
      "lpm" & $cases, deepest = "/s/run/ep/12345678/logos_fetch_fake_module.sock"
    )
    result.s = Session(dir: result.dir / "s")

  proc ctl(c: Case, args: varargs[string]): Ran =
    runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "--text"] & @args,
      c.dir,
      timeoutMs = 120_000 * Slow,
    )

  proc call(c: Case, args: varargs[string]): JsonNode =
    ## `logosctl call` through `lcn_call`: its JSON (stdout is a file, G89), or null.
    let r = runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "call"] & @args,
      c.dir,
      timeoutMs = 120_000 * Slow,
    )
    try:
      result = parseJson(r.stdout)
    except CatchableError:
      checkpoint("not JSON: " & r.stdout & r.stderr)
      result = newJNull()
    if r.code != 0:
      checkpoint(
        "logosctl call " & args.join(" ") & ": exit " & $r.code & ": " & r.stderr
      )

  proc hosted(
      instance, module, lib: string,
      root: seq[byte],
      state: string,
      implements: seq[seq[byte]] = @[],
  ): LcnAppModule =
    result = LcnAppModule(
      instance: instance,
      module: module,
      primary_contract: Opt.some(SchemaCommitment(schema_root: root)),
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Process_hosted_dynamic,
        arm_Process_hosted_dynamic: LcnAppImplementationARProcessHostedDynamicMap(
          artifact: LcnAppArtifact(id: module, local_path: lib, hash: digestOfFile(lib))
        ),
      ),
      state_assignment: Opt.some(state),
    )
    if implements.len > 0:
      var commitments: seq[SchemaCommitment]
      for r in implements:
        commitments.add(SchemaCommitment(schema_root: r))
      result.implements = Opt.some(commitments)

  proc callerRule(root: seq[byte], discoverOnly = false): LcnApRule =
    ## [DAEMON.md §7a] `lcn_call` may reach the provider of `root`: discover, a route, calls.
    ## `discoverOnly`: discover alone, for a provider's other contract, since the Runtime
    ## describes a provider only to a caller that may discover each of its contracts
    ## (RUNTIME l.428).
    var actions = @[LcnApAction(kind: LcnApActionKind.Discover)]
    if not discoverOnly:
      actions.add(LcnApAction(kind: LcnApActionKind.Establish_route))
      actions.add(LcnApAction(kind: LcnApActionKind.Renew_route))
      actions.add(LcnApAction(kind: LcnApActionKind.Call))
    sortSet(actions)
    LcnApRule(
      kind: LcnApRuleKind.lcn_Ap_allow,
      arm_lcn_Ap_allow: LcnApAllow(
        subject: LcnApSubject(instances: Opt.some(@[CliInstance])),
        scopes: @[
          LcnApScope(
            kind: LcnApScopeKind.lcn_Ap_provider_access,
            arm_lcn_Ap_provider_access: LcnApProviderAccess(
              contract: LcnApProviderAccessContractChoice(
                kind: LcnApProviderAccessContractChoiceKind.logos_Schema_commitment,
                arm_logos_Schema_commitment: SchemaCommitment(schema_root: root),
              ),
              actions: actions,
            ),
          )
        ],
      ),
    )

  proc pmConfig(): LcnDaemonConfig =
    ## The default configuration with the fake and the Package Manager, both started by the
    ## orchestrator, the `package_manager` section with logosd's preset, `lcn_call` granted both
    ## providers, and nothing granted to the two instances.
    result = defaultDaemonConfig("assigned-by-init")
    result.runtime.module_host = Opt.some(hostExe)
    result.runtime.module_host_env = Opt.some(@SanitizerEnv)
    when Slow > 1:
      result.runtime.stop_deadline_ms = Opt.some(uint32(StopDeadlineMs))
      result.runtime.shutdown_grace_ms = Opt.some(uint32(StopDeadlineMs))
    result.modules = Opt.some(
      @[
        hosted(
          FakeInstance,
          "fetch_fake_module",
          fakeLib,
          fakeRoot,
          FakeState,
          implements = @[@LcnStorageFetchRoot],
        ),
        hosted(PmInstance, "pmtest_module", pmLib, pmRoot, PmState),
      ]
    )
    var o = result.orchestration.get(LcnDcOrchestration())
    o.start = Opt.some(@[FakeInstance, PmInstance])
    result.orchestration = Opt.some(o)
    result.package_manager = Opt.some(
      LcnDcPackageManager(
        instance: PmInstance,
        storage:
          @[daemon_config_types.LcnPmBinding(binding: "main", instance: FakeInstance)],
        catalog: daemon_config_types.LcnPmCatalogRef(
          storage: "main",
          `object`: bytesOf("fetch-fake/state/" & CatalogName),
          digest: @(blake3(document)),
        ),
      )
    )
    result.policy.arm_Capability_authority.rules = @[
      callerRule(fakeRoot),
      callerRule(@LcnStorageFetchRoot, discoverOnly = true),
      callerRule(pmRoot),
    ]
    sortSet(result.policy.arm_Capability_authority.rules)
    result.cli = Opt.some(LcnDcCli(artifact: Opt.some(cliArt)))

  proc initPm(c: Case): Ran =
    let path = c.dir / "config.cbor"
    writeFile(path, cast[string](pmConfig().encode.expect("an encoding")))
    c.ctl("init", "--config", "@" & path)

  proc stock(c: Case) =
    ## The fake's `objects/`: the catalog and the archives, written before the start, each
    ## directory private as logosd makes its own.
    let fake = c.s.modulesDir / FakeState
    for d in [c.s.stateDir, c.s.modulesDir, fake, fake / "objects"]:
      check ensurePrivateDir(d).isOk
    writeFile(fake / "objects" / CatalogName, textOf(document))
    for (name, bytes) in objects:
      writeFile(fake / "objects" / name, textOf(bytes))

  proc start(c: Case, name = "logosd"): Child =
    result = spawnChild(dExe, ["--session-dir", c.s.dir], c.dir, name)
    children.add(result)

  proc stopped(d: Child): int =
    result = stopChild(d, StopMs)
    if result != 0:
      checkpoint("logosd stderr:\n" & d.errText)

  proc expectReady(c: Case, d: Child) =
    ## The socket answers `status`, or the case fails with logosd's stderr.
    let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
    while getMonoTime() < until and d.alive:
      if entryExists(c.s.socketPath()) and c.ctl("status").code == 0:
        return
      sleep(20)
    checkpoint("logosd stderr:\n" & d.errText)
    fail()

  proc eventually(what: string, d: Child, cond: proc(): bool): bool =
    ## `cond` holds within `ReadyMs`; else the case says what it waited for.
    let until = getMonoTime() + initDuration(milliseconds = ReadyMs)
    while getMonoTime() < until:
      if cond():
        return true
      sleep(50)
    checkpoint("waited for " & what & "; logosd stderr:\n" & d.errText)
    false

  proc status(c: Case): JsonNode =
    c.call("pmtest_module", "status"){"result"}

  proc firstBinding(status: JsonNode): JsonNode =
    ## The status's one binding, or nil while it has none: early in a start, or when
    ## the call failed. `{}` and `getStr` accept nil; `len` and `[]` do not.
    let b = status{"bindings"}
    if b != nil and b.kind == JArray and b.len == 1:
      b[0]
    else:
      nil

  proc readinessOf(c: Case): string =
    ## The one binding's readiness as the Package Manager last learned it.
    c.status().firstBinding{"readiness"}.getStr

  proc setReadiness(c: Case, to: string): bool =
    let j = c.call(
      "fetch_fake_module",
      "set_readiness",
      "--request",
      "{\"readiness\": \"" & to & "\", \"held\": []}",
    )
    j{"status"}.getStr == "ok"

  proc resolveReply(c: Case, name, version: string): JsonNode =
    c.call("pmtest_module", "resolve", "name=" & name, "version=" & version)

  proc resolved(c: Case, name, version: string): JsonNode =
    ## The resolve's result, or nil when the call failed: for a wait, which asks again.
    c.resolveReply(name, version){"result"}

  type NoResult = object of CatchableError
    ## [IMPL] A call without a `result` where its case reads one: raised to fail and stop
    ## the case, whose teardown still stops logosd. unittest2's `require` would quit the
    ## process without it.

  proc resolution(c: Case, name, version: string): JsonNode =
    ## The resolve's result, read once and logged. With none, as under load (about 120 on
    ## the Mac), the case fails naming the call and its reply, and stops. `$` of the nil
    ## crashed the process instead, which skipped the teardown, and the orphaned logosd
    ## kept respawning its Module Hosts.
    let reply = c.resolveReply(name, version)
    result = reply{"result"}
    if result.isNil:
      raise newException(
        NoResult,
        "pmtest_module resolve name=" & name & " version=" & version &
          ": no result; the reply: " & $reply,
      )
    checkpoint($result)

  proc packagesOf(r: JsonNode): seq[string] =
    for p in r{"packages"}.getElems:
      result.add(p{"package"}.getStr & "@" & p{"version"}.getStr)

  proc hostsGone(): bool =
    let until = getMonoTime() + initDuration(milliseconds = HostsGoneMs)
    while hostPids().len > 0:
      if getMonoTime() >= until:
        return false
      sleep(20)
    true

  func presetLine(): string =
    "package_manager: " & PmInstance & " gets resolver limits partial_closure_names " &
      $PresetPartialClosureNames & ", dependency_depth " & $PresetDependencyDepth &
      ", candidates_per_name " & $PresetCandidatesPerName & ", assignment_attempts " &
      $PresetAssignmentAttempts & " (logosd's preset)"

  proc ready(c: Case): Child =
    ## logosd started on the case's session, answering, with the Package Manager `ready` and
    ## its binding's readiness learned.
    result = c.start("logosd" & $children.len)
    c.expectReady(result)
    let d = result
    check eventually(
      "the Package Manager's binding to have a readiness",
      d,
      proc(): bool =
        c.readinessOf().len > 0,
    )

  suite "daemon.logosd_pm: logosd with a package_manager section (DAEMON.md §3, §5) [IMPL-DECISION G399] [IMPL-DECISION G400] [IMPL-DECISION G402] [IMPL-DECISION G405]":
    teardown:
      for ch in children:
        if ch.alive:
          discard stopChild(ch, StopMs)
      children = @[]
      killAll()
      if not hostsGone():
        checkpoint("Module Hosts left: " & $hostPids())
        for pid in hostPids():
          discard kill(Pid(pid), SIGKILL)
        fail()

    test "[PKG-0353] [IMPL-DECISION G402] the Package Manager starts on the session's trust, acquires the catalog on the fake's event (S9 to S11 under capability-authority), and resolves":
      let c = newCase()
      check c.initPm().code == 0
      c.stock()
      check c.ctl(
        "trust", "anchor", "add", "--kid", "org", "--key", hexOf(orgPub), "app", "lib"
      ).code == 0
      let d = c.ready()
      # [G399; ruling C3] The limits and their origin, in the operator's log.
      check presetLine() in d.errText
      # [G400] The protected input was read during `_MODULE_init` and removed after it.
      check not fileExists(c.s.modulesDir / PmState / ProtectedInputName)
      let before = c.status()
      check before{"catalog"}.isNil
      check c.readinessOf() == "starting"
      check before.firstBinding{"state"}.getStr == "ready"
      check before.firstBinding{"established"}.getInt == 1
      check c.resolved("app", "1.0.0"){"error"}.getStr == "package-unavailable"
      # [S10, S11] The fake publishes `fetch_readiness_changed`; the Package Manager acquires
      # the catalog on it, since it asks `fetch_readiness` only once per route.
      check c.setReadiness("ready")
      check eventually(
        "the catalog",
        d,
        proc(): bool =
          not c.status(){"catalog"}.isNil,
      )
      let now = c.status()
      check now{"catalog"}{"entries"}.getInt == 2
      check now{"catalog"}{"sequence"}.getInt == 1
      check "package-manager: the configured catalog is in use: sequence 1, 2 entries, digest " &
        hexOf(blake3(document)) in d.errText
      check "no readiness subscription" notin d.errText
      # The archives verify against the session's anchor.
      let r = c.resolution("app", "1.0.0")
      check r.packagesOf == @["app@1.0.0", "lib@1.2.0"]
      check c.status(){"pending"}.getInt == 0
      check d.stopped == 0
      check hostsGone()

    test "[IMPL-DECISION G399] [BCP-0049] a trust change applies at the next start: a name removed from the anchor is withdrawn, and the kept catalog is in use at once":
      let c = newCase()
      check c.initPm().code == 0
      c.stock()
      check c.ctl(
        "trust", "anchor", "add", "--kid", "org", "--key", hexOf(orgPub), "app", "lib"
      ).code == 0
      let first = c.ready()
      check c.setReadiness("ready")
      check eventually(
        "the first resolve",
        first,
        proc(): bool =
          c.resolved("app", "1.0.0").packagesOf == @["app@1.0.0", "lib@1.2.0"],
      )
      check first.stopped == 0
      # Offline, under the session lock (DAEMON.md §6): `lib` leaves the anchor.
      let change = c.ctl("trust", "anchor", "remove-names", "--kid", "org", "lib")
      checkpoint(change.stdout & change.stderr)
      check change.code == 0
      check "it applies at the next start" in change.stdout
      let second = c.ready()
      check "package-manager: the kept catalog is in use: sequence 1, 2 entries, digest " &
        hexOf(blake3(document)) in second.errText
      check c.status(){"catalog"}{"entries"}.getInt == 2
      check c.setReadiness("ready")
      check eventually(
        "the fake's readiness",
        second,
        proc(): bool =
          c.readinessOf() == "ready",
      )
      # `lib`'s archive is signed by `org`, whose anchor no longer authorizes the name: `app`
      # has no closure, and `lib` as a root is refused.
      let r = c.resolution("app", "1.0.0")
      check r.packagesOf.len == 0
      check r{"error"}.getStr == "dependency-unavailable"
      let l = c.resolution("lib", "1.2.0")
      check l{"error"}.getStr == "signature-verification-failed"
      check second.stopped == 0
      check hostsGone()
