## logosd with a `package_manager` section (Tier 5 steps 5-3b-2 and 5-6a-1; DECISIONS
## G399, G400, G402, G405, G490, G491; docs/DAEMON.md §3 and §5,
## docs/PACKAGE-MANAGER.md §4). logosd composes the Package Manager itself: the reserved
## instance `package_manager` of `logos_package_manager`, hosted in its own process (C1),
## from `package_manager.artifact` (`support/pmbuild.nim`'s library, since a test logosd
## has no companion library's hash) or, in the companion case, from the library beside a
## logosd built with that hash. The reference fake (`fetch_fake_module`) is its one
## storage provider, serving a catalog and signed archives from its state directory
## (`fetch-fake/state/<name>`), an operator instance the orchestrator starts.
##
## The test drives the fake and calls the Package Manager as an operator would, with
## `logosctl call` through `lcn_call` (DAEMON.md §7a); an operator rule grants `lcn_call`
## both providers. No operator rule grants the Package Manager or the fake anything, and
## no operator entry names the Package Manager: its start passes on rule S2, its
## `list_modules` lookup and its route (S9), its readiness subscription (S10) and the
## fake's event (S11) on logosd's derived rules alone, and S12 keeps the shell from
## retiring or reconfiguring it. The catalog is acquired only once the fake is ready. The
## package-signing trust is the session's trust file, written with `logosctl trust`; a
## change to it applies at the next start.
##
## The children are built for the suite's variant (`daemonbuild.nim`), as in
## `test_logosd.nim`. Every case leaves no Module Host of this build behind.

when defined(posix):
  import std/[json, monotimes, os, sequtils, strutils, times]
  import unittest2
  import logos_sdk/cbor
  import logos_sdk/crypto/blake3
  import ../src/logos_core/daemon/[config, daemon_config_types, session, sessioninit]
  import ../src/logos_core/pins as core_pins
  from ../src/logos_core/daemon/compose import PmLibrary
  from ../src/logos_core/authority/scopes import sortSet
  from ../src/logos_core/durable import ensurePrivateDir, writeAtomic
  from ../src/logos_core/runtime/protinput import ProtectedInputName
  from logos_sdk/iface/accept import acceptContractSet, AcceptOptions
  from logos_sdk/contracts/generated/lcn_storage_fetch_root import LcnStorageFetchRoot
  import
    ./support/[
      childbuild, clibuild, daemonbuild, daemonproc, modulehostbuild, pmbuild,
      pmfixture, sanitizerenv, shortdir, signals, slowdown,
    ],
    logos_sdk/testing/kitbuild

  import std/posix

  const
    ReadyMs = 120_000 * Slow
      ## [IMPL] Only bounds a wait for what comes, as in `test_logosd.nim`.
    StopDeadlineMs = 10_000 * Slow
    StopMs = 3 * StopDeadlineMs
    HostsGoneMs = 10_000 * Slow
    RestartInitialMs = 200
      ## [IMPL] The operator's restart policy in the override case: an instance it
      ## covers is started again within this.
    NoRestartMs = 3_000 * Slow
      ## [IMPL] How long the override case watches the Package Manager stay down: many
      ## times `RestartInitialMs`.
    FakeInstance = "fetch-1"
    FakeState = "fetch-1"
    PmState = "pm"
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
    pmLib = pmLibrary()
    fakeRoot = @(
      acceptContractSet(
        readFile(repo / "sdk/src/logos_sdk/testing/fixtures/fetch_fake_module.cddl"),
        [readFile(repo / "sdk/src/logos_sdk/contracts/lcn_storage_fetch.cddl")],
      )
      .expect("the fetch_fake_module contract set").primary.root
    )
    # [SPEC PM App A; G490] The Package Manager's contract, from the pinned documents.
    pmRoot = @(
      acceptContractSet(
        core_pins.PackageManagerContractDocument,
        [],
        [
          core_pins.PackageManifestDocument,
          readFile(repo / "spec/mirrors/CFG/9.configuration-types.cddl"),
        ],
        AcceptOptions(system: true),
      )
      .expect("the Package Manager contract set").primary.root
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
  var companionD = ""

  func hexOf(bytes: openArray[byte]): string =
    for b in bytes:
      result.add(toHex(b, 2).toLowerAscii)

  proc digestOfFile(path: string): seq[byte] =
    let bytes = readFile(path)
    @(blake3(bytes.toOpenArrayByte(0, bytes.high)))

  proc companionLogosd(): string =
    ## [G491] A test logosd built with the BLAKE3-256 of this suite's Package Manager
    ## library compiled in (`pmArtifactHash`), as the flake builds the packaged one; it
    ## shares the test logosd's nimcache, so only the composition is compiled again.
    if companionD.len == 0:
      companionD = buildChild(
        "src/logosd.nim",
        "logosd-pm",
        "logosd",
        @["lcnTestHooks", "pmArtifactHash=" & hexOf(digestOfFile(pmLib))],
      )
    companionD

  type Case = object
    dir: string ## the case's directory: the session is `dir/s`
    s: Session

  proc newCase(): Case =
    inc cases
    result.dir = makeShortBase(
      "lpm" & $cases,
      deepest = "/s/run/ep/12345678/logos_logos_package_manager.sock",
      perCase = true,
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
    ## `logosctl call` through `lcn_call`: its JSON envelope (stdout is a file, G89), or
    ## null.
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
        "logosctl call " & args.join(" ") & ": exit " & $r.code & ": " & r.stdout &
          r.stderr
      )

  proc pm(c: Case, meth: string, args: varargs[string]): JsonNode =
    ## A Package Manager method through `lcn_call`: its envelope.
    c.call(@[PmModule, meth] & @args)

  func codeOf(j: JsonNode): string =
    ## The response's `package_error` code; empty for a success.
    j{"result"}{"error"}{"code"}.getStr

  func installedOf(j: JsonNode): string =
    ## `{installed: record}`'s identity, as `package@version`.
    let id = j{"result"}{"installed"}{"identity"}
    if id.isNil:
      ""
    else:
      id{"package"}.getStr & "@" & id{"version"}.getStr

  proc identityRequest(field, package, version: string): seq[string] =
    @["--request", $(%*{field: {"package": package, "version": version}})]

  proc moduleOf(c: Case, instance: string): JsonNode =
    ## The instance's record in `logosctl --json module ls`, or nil.
    let r = runOnce(
      ctlExe,
      @["--session-dir", c.s.dir, "--json", "module", "ls"],
      c.dir,
      timeoutMs = 120_000 * Slow,
    )
    try:
      for m in parseJson(r.stdout){"result"}{"modules"}.getElems:
        if m{"instance"}.getStr == instance:
          return m
    except CatchableError:
      discard
    nil

  proc stateOf(c: Case, instance: string): string =
    c.moduleOf(instance){"state"}.getStr

  proc failureOf(c: Case, instance: string): string =
    c.moduleOf(instance){"failure"}.getStr

  proc routed(c: Case): bool =
    ## `logosctl route ls` shows the Package Manager's route to the fake, `ready`.
    for line in c.ctl("route", "ls").stdout.splitLines:
      let f = line.splitWhitespace
      if f.len == 5 and f[2] == PmInstance and f[3] == FakeInstance and f[4] == "ready":
        return true
    false

  proc hostedEntry(
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

  proc pmSection(
      artifact = Opt.some(pmArtifact(pmLib)), storageInstance = FakeInstance
  ): LcnDcPackageManager =
    LcnDcPackageManager(
      state: PmState,
      artifact: artifact,
      storage:
        @[daemon_config_types.LcnPmBinding(binding: "main", instance: storageInstance)],
      catalog: daemon_config_types.LcnPmCatalogRef(
        storage: "main",
        `object`: bytesOf("fetch-fake/state/" & CatalogName),
        digest: @(blake3(document)),
      ),
    )

  proc pmConfig(section = pmSection()): LcnDaemonConfig =
    ## The default configuration with the fake, which the orchestrator starts, the
    ## `package_manager` section (logosd composes and starts the instance), `lcn_call`
    ## granted both providers, and nothing granted to the two instances.
    result = defaultDaemonConfig("assigned-by-init")
    result.runtime.module_host = Opt.some(hostExe)
    result.runtime.module_host_env = Opt.some(@SanitizerEnv)
    when Slow > 1:
      result.runtime.stop_deadline_ms = Opt.some(uint32(StopDeadlineMs))
      result.runtime.shutdown_grace_ms = Opt.some(uint32(StopDeadlineMs))
    result.modules = Opt.some(
      @[
        hostedEntry(
          FakeInstance,
          "fetch_fake_module",
          fakeLib,
          fakeRoot,
          FakeState,
          implements = @[@LcnStorageFetchRoot],
        )
      ]
    )
    var o = result.orchestration.get(LcnDcOrchestration())
    o.start = Opt.some(@[FakeInstance])
    result.orchestration = Opt.some(o)
    result.package_manager = Opt.some(section)
    result.policy.arm_Capability_authority.rules = @[
      callerRule(fakeRoot),
      callerRule(@LcnStorageFetchRoot, discoverOnly = true),
      callerRule(pmRoot),
    ]
    sortSet(result.policy.arm_Capability_authority.rules)
    result.cli = Opt.some(LcnDcCli(artifact: Opt.some(cliArt)))

  proc initWith(c: Case, bytes: seq[byte], extra: varargs[string]): Ran =
    let path = c.dir / "config.cbor"
    writeFile(path, textOf(bytes))
    c.ctl(@["init", "--config", "@" & path] & @extra)

  proc initPm(c: Case, dc = pmConfig(), extra: varargs[string]): Ran =
    c.initWith(dc.encode.expect("an encoding"), extra)

  proc editConfig(c: Case, edit: proc(dc: var LcnDaemonConfig)) =
    ## Offline, as `daemon config set` would: the session's configuration, changed.
    var (dc, _) = readDaemonConfig(c.s).expect("the daemon-config")
    edit(dc)
    check writeAtomic(c.s.dir, DaemonConfigName, dc.encode.expect("bytes")).isOk

  proc stock(c: Case) =
    ## The fake's `objects/`: the catalog and the archives, written before the start, each
    ## directory private as logosd makes its own.
    let fake = c.s.modulesDir / FakeState
    for d in [c.s.stateDir, c.s.modulesDir, fake, fake / "objects"]:
      check ensurePrivateDir(d).isOk
    writeFile(fake / "objects" / CatalogName, textOf(document))
    for (name, bytes) in objects:
      writeFile(fake / "objects" / name, textOf(bytes))

  proc anchor(c: Case) =
    check c.ctl(
      "trust", "anchor", "add", "--kid", "org", "--key", hexOf(orgPub), "app", "lib"
    ).code == 0

  proc start(c: Case, exe = dExe): Child =
    result =
      spawnChild(exe, ["--session-dir", c.s.dir], c.dir, "logosd" & $children.len)
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

  proc reaches(c: Case, d: Child, instance, state: string): bool =
    eventually(
      instance & " to be " & state,
      d,
      proc(): bool =
        c.stateOf(instance) == state,
    )

  proc ready(c: Case, exe = dExe): Child =
    ## logosd started on the case's session, answering, with the Package Manager `ready`.
    result = c.start(exe)
    c.expectReady(result)
    check c.reaches(result, PmInstance, "ready")

  proc setReadiness(c: Case, to: string): bool =
    let j = c.call(
      "fetch_fake_module",
      "set_readiness",
      "--request",
      "{\"readiness\": \"" & to & "\", \"held\": []}",
    )
    j{"status"}.getStr == "ok"

  proc acquired(c: Case, d: Child, line: string): bool =
    ## The catalog line `line` is in logosd's log and `app`'s inspection succeeds.
    eventually(
      "the catalog",
      d,
      proc(): bool =
        line in d.errText and
          not c.pm("inspect_package", "package=app", "version=1.0.0"){"result"}{
            "inspection"
          }.isNil,
    )

  proc catalogLine(kind: string): string =
    "package-manager: the " & kind & " catalog is in use: sequence 1, 2 entries, digest " &
      hexOf(blake3(document))

  proc records(c: Case): int =
    ## The record directories below the Package Manager's `install/r/`.
    let d = c.s.modulesDir / PmState / "install" / "r"
    if dirExists(d):
      toSeq(walkDir(d)).len
    else:
      0

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

  proc refusedWith(r: Ran, text: string): bool =
    ## The command failed and its stderr holds `text`.
    checkpoint("exit " & $r.code & ": " & r.stdout & r.stderr)
    r.code != 0 and text in r.stderr

  suite "daemon.logosd_pm: logosd composes the Package Manager from its package_manager section (DAEMON.md §3, §5) [IMPL-DECISION G399] [IMPL-DECISION G400] [IMPL-DECISION G402] [IMPL-DECISION G405] [IMPL-DECISION G490] [IMPL-DECISION G491]":
    teardown:
      for ch in children:
        if ch.alive:
          discard stopChild(ch, StopMs)
      children = @[]
      killAll()
      if not hostsGone():
        checkpoint("Module Hosts left: " & $hostPids())
        for pid in hostPids():
          discard signalPid(pid, SIGKILL)
        fail()
      # The case's directories, its children's output files with them: kept
      # if it failed (`shortdir`).
      endCaseBases(testStatusIMPL == TestStatus.FAILED)

    test "[PKG-0004] [PKG-0353] [PKG-0513] [IMPL-DECISION G491] [IMPL-DECISION G402] [IMPL-DECISION G449] [IMPL-DECISION G493] under capability-authority, with no operator entry for it: the Package Manager is started (S2), acquires the catalog once the fake is ready (S9 to S11), the operations run end to end, and the records are kept across logosd's restart":
      let c = newCase()
      check c.initPm().code == 0
      c.stock()
      c.anchor()
      let first = c.ready()
      let pmRec = c.moduleOf(PmInstance)
      check pmRec{"module"}.getStr == PmModule
      check pmRec{"state_assignment"}.getStr == PmState
      # [G399; ruling C3] The limits and their origin, in the operator's log.
      check presetLine() in first.errText
      # [G400] The protected input was read during `_MODULE_init` and removed after it.
      check not fileExists(c.s.modulesDir / PmState / ProtectedInputName)
      # [S9] Its route to the fake, on logosd's rules alone.
      check eventually(
        "the Package Manager's route to the fake",
        first,
        proc(): bool =
          c.routed(),
      )
      # No catalog yet: the fake is `starting`.
      check c.pm("inspect_package", "package=app", "version=1.0.0").codeOf ==
        "package-unavailable"
      # [S10, S11] The fake becomes ready; the Package Manager acquires the catalog.
      check c.setReadiness("ready")
      check c.acquired(first, catalogLine("configured"))
      check "no readiness subscription" notin first.errText
      # [G493; I141] The Runtime's system-service binding, in the operator's log.
      check eventually(
        "the system-service binding",
        first,
        proc(): bool =
          ("the system-service binding of " & PmInstance & " is ready") in first.errText,
      )
      # With a catalog in use (without one, any resolution is package-unavailable first),
      # an update of a package not installed.
      check c.pm("update_package", identityRequest("current", "app", "1.0.0")).codeOf ==
        "package-not-installed"
      let a = c.pm("install_package", "package=app", "version=1.0.0")
      checkpoint("the install: " & $a)
      check a.installedOf == "app@1.0.0"
      check c.records == 2
      # [G449] The operation's log line: its time and the archive bytes it retrieved.
      check "package-manager: install_package ended after " in first.errText
      check "archive bytes retrieved: committed" in first.errText
      # [G495; Q7 (b)] An observation is not served before 5-6b: MODULE_ERROR with no
      # message, and the operator's log line.
      let listed = c.pm("list_installed_packages")
      check listed{"status"}.getStr == "error"
      check listed{"code"}.getStr == "MODULE_ERROR"
      check listed{"message"}.isNil
      check eventually(
        "the refusal's log line",
        first,
        proc(): bool =
          "package-manager: list_installed_packages refused for module instance " &
            CliInstance & " of Runtime " in first.errText,
      )
      check first.stopped == 0
      # The next start: the fake is not made ready, so nothing is retrieved; the
      # catalog and the records come from what the Package Manager kept.
      let second = c.ready()
      check eventually(
        "the kept catalog",
        second,
        proc(): bool =
          catalogLine("kept") in second.errText,
      )
      check c.pm("remove_package", identityRequest("identity", "lib", "1.2.0")).codeOf ==
        "package-in-use"
      let removed = c.pm("remove_package", identityRequest("identity", "app", "1.0.0"))
      # The status first: a failed call has no `result`, and is reported, not read.
      check removed{"status"}.getStr == "ok"
      if removed{"status"}.getStr == "ok":
        let res = removed{"result"}
        check res != nil and res.kind == JObject and res.len == 0
      check c.pm("remove_package", identityRequest("identity", "lib", "1.2.0")).codeOf ==
        ""
      check eventually(
        "the removed records to be collected",
        second,
        proc(): bool =
          c.records == 0,
      )
      check second.stopped == 0
      check hostsGone()

    test "[IMPL-DECISION G399] [BCP-0049] a trust change applies at the next start: a name removed from the anchor is withdrawn, and the kept catalog is in use at once":
      let c = newCase()
      check c.initPm().code == 0
      c.stock()
      c.anchor()
      let first = c.ready()
      check c.setReadiness("ready")
      check c.acquired(first, catalogLine("configured"))
      check first.stopped == 0
      # Offline, under the session lock (DAEMON.md §6): `lib` leaves the anchor.
      let change = c.ctl("trust", "anchor", "remove-names", "--kid", "org", "lib")
      checkpoint(change.stdout & change.stderr)
      check change.code == 0
      check "it applies at the next start" in change.stdout
      let second = c.ready()
      check c.setReadiness("ready")
      # `lib`'s archive is signed by `org`, whose anchor no longer authorizes the name:
      # `lib` is refused, and `app` has no closure.
      check eventually(
        "lib's inspection to be refused",
        second,
        proc(): bool =
          c.pm("inspect_package", "package=lib", "version=1.2.0").codeOf ==
            "signature-verification-failed",
      )
      check catalogLine("kept") in second.errText
      let r = c.pm("install_package", "package=app", "version=1.0.0")
      checkpoint($r)
      check r.codeOf == "dependency-unavailable"
      check c.records == 0
      check second.stopped == 0
      check hostsGone()

    test "[IMPL-DECISION G491] [IMPL-DECISION G402] ordering and overrides may name package_manager and take effect; the shell may stop, start and recover it, and may not retire or reconfigure it (S12)":
      let c = newCase()
      var dc = pmConfig()
      # The Package Manager after the fake; the operator's restart policy for every
      # instance but the Package Manager.
      dc.ordering =
        Opt.some(@[LcnAppOrdering(prerequisite: FakeInstance, dependent: PmInstance)])
      var o = dc.orchestration.get
      o.restart = Opt.some(
        LcnDcRestart(
          kind: LcnDcRestartKind.Backoff,
          arm_Backoff: LcnDcRestartARBackoffMap(
            initial_delay_ms: RestartInitialMs,
            max_delay_ms: 2 * RestartInitialMs,
            multiplier: 2,
            stable_ms: 1000,
          ),
        )
      )
      o.overrides = Opt.some(
        @[
          LcnDcOverride(
            instance: PmInstance, restart: LcnDcRestart(kind: LcnDcRestartKind.Disabled)
          )
        ]
      )
      dc.orchestration = Opt.some(o)
      check c.initPm(dc).code == 0
      c.stock()
      c.anchor()
      let d = c.ready()
      check c.reaches(d, FakeInstance, "ready")
      # [S12] Target-denied for the shell: retire, a staged value, an apply.
      check c.ctl("module", "retire", PmInstance).refusedWith("NOT_AUTHORISED")
      let value = c.dir / "value.cbor"
      writeFile(value, "\xA0")
      check c
        .ctl(
          "config",
          "stage",
          PmInstance,
          "@" & value,
          "--revision",
          "0",
          "--schema",
          repeat('0', 128),
        )
        .refusedWith("NOT_AUTHORISED")
      check c.ctl("config", "apply", PmInstance, "--revision", "1").refusedWith(
        "NOT_AUTHORISED"
      )
      check c.stateOf(PmInstance) == "ready"
      # [S12] The shell may stop and start it; the ordering holds for it: with the fake
      # stopped, its start waits for a prerequisite.
      check c.ctl("module", "stop", PmModule, "--instance", PmInstance).code == 0
      check c.reaches(d, PmInstance, "unloaded")
      check c.ctl("module", "stop", "fetch_fake_module", "--instance", FakeInstance).code ==
        0
      check c.reaches(d, FakeInstance, "unloaded")
      check c.ctl("module", "start", PmModule, "--instance", PmInstance).refusedWith(
        "NOT_READY"
      )
      check c.failureOf(PmInstance) == "prerequisite-unavailable"
      check c.ctl("module", "start", "fetch_fake_module", "--instance", FakeInstance).code ==
        0
      check c.reaches(d, FakeInstance, "ready")
      # Its intent is `requested`: the orchestrator may start it as well, so either
      # start may be the one that runs.
      let again = c.ctl("module", "start", PmModule, "--instance", PmInstance)
      checkpoint(again.stdout & again.stderr)
      check c.reaches(d, PmInstance, "ready")
      # Its host, found as the one a start of it adds (no `logosctl call` here, so
      # lcn_call is not started meanwhile).
      check c.ctl("module", "stop", PmModule, "--instance", PmInstance).code == 0
      check c.reaches(d, PmInstance, "unloaded")
      let before = hostPids()
      check c.ctl("module", "start", PmModule, "--instance", PmInstance).code == 0
      check c.reaches(d, PmInstance, "ready")
      let pmHost = hostPids().filterIt(it notin before)
      check pmHost.len == 1
      if pmHost.len == 1:
        # The override: its host ends, and nothing starts it again.
        check signalPid(pmHost[0], SIGKILL) == 0
        check c.reaches(d, PmInstance, "error")
        sleep(NoRestartMs)
        check c.stateOf(PmInstance) == "error"
        # [S12] The shell may recover it.
        let r = c.ctl("module", "recover", PmInstance)
        checkpoint(r.stdout & r.stderr)
        check r.code == 0
        check c.reaches(d, PmInstance, "ready")
      check d.stopped == 0
      check hostsGone()

    test "[IMPL-DECISION G491] under allow-all, with the development switch, the Package Manager is started with no operator entry for it":
      let c = newCase()
      var dc = pmConfig()
      dc.policy = LcnDcPolicy(kind: LcnDcPolicyKind.Allow_all)
      check c.initPm(dc, "--development").code == 0
      c.stock()
      c.anchor()
      let d = c.ready()
      check "development switch" in d.errText
      check c.pm("inspect_package", "package=app", "version=1.0.0").codeOf ==
        "package-unavailable"
      check c.setReadiness("ready")
      check c.acquired(d, catalogLine("configured"))
      check d.stopped == 0
      check hostsGone()

    test "[PKG-0513] [PKG-0514] [IMPL-DECISION G491] the companion library: composed from it when the section gives no artifact, refused at realization once its bytes differ from the compiled digest; package_manager.artifact overrides it, and its own digest is checked":
      let c = newCase()
      # The packaged layout: logosd in `bin/`, the library in `lib/logos-core/`.
      let pkg = c.dir / "pkg"
      createDir(pkg / "bin")
      createDir(pkg / "lib" / "logos-core")
      let exe = pkg / "bin" / "logosd"
      copyFileWithPermissions(companionLogosd(), exe)
      let companion = pkg / "lib" / "logos-core" / PmLibrary
      copyFile(pmLib, companion)
      check c.initPm(pmConfig(pmSection(artifact = Opt.none(LcnAppArtifact)))).code == 0
      c.stock()
      c.anchor()
      let first = c.ready(exe)
      check c.setReadiness("ready")
      check c.acquired(first, catalogLine("configured"))
      check first.stopped == 0
      # [PKG-0514] Its bytes no longer match the compiled digest.
      block:
        var f = open(companion, fmAppend)
        f.write("\0")
        f.close()
      let second = c.start(exe)
      c.expectReady(second)
      check eventually(
        "the integrity refusal",
        second,
        proc(): bool =
          c.failureOf(PmInstance) == "loader-artifact-integrity-failed",
      )
      check second.stopped == 0
      # The section's artifact wins over the companion library.
      c.editConfig(
        proc(dc: var LcnDaemonConfig) =
          dc.package_manager.get.artifact = Opt.some(pmArtifact(pmLib))
      )
      let third = c.ready(exe)
      check third.stopped == 0
      # [PKG-0514] And its own digest is checked, at realization. On a session of its own:
      # here, where the instance is retained, a changed digest is a changed declaration fact,
      # which the start refuses before anything runs (G160's reconcile; G491's open item).
      let d = newCase()
      var a = pmArtifact(pmLib)
      a.hash = digestOfFile(fakeLib)
      check d.initPm(pmConfig(pmSection(artifact = Opt.some(a)))).code == 0
      d.stock()
      d.anchor()
      let fourth = d.start(exe)
      d.expectReady(fourth)
      check eventually(
        "the integrity refusal",
        fourth,
        proc(): bool =
          d.failureOf(PmInstance) == "loader-artifact-integrity-failed",
      )
      check fourth.stopped == 0
      check hostsGone()
      removeDir(pkg)

    test "[IMPL-DECISION G491] [IMPL-DECISION G490] refused before anything starts: the old package_manager.instance, orchestration.start naming package_manager, a Storage binding to package_manager, a logos_ operator module; a section with no artifact passes the shell's checks and this logosd, with no companion library, refuses it at start":
      # The old field, named with its replacements (raw CBOR: the type no longer has it).
      block:
        let c = newCase()
        var v = decodeCbor(pmConfig().encode.expect("an encoding")).expect("CBOR")
        for e in v.entries.mitems:
          if e.key.getText.get("") == "package_manager":
            e.value.entries.add((cbor("instance"), cbor("pm-1")))
        check c.initWith(encodeCbor(v)).refusedWith(
          "--config: package_manager.instance is no longer a field: logosd composes the " &
            "Package Manager itself as the instance package_manager; give " &
            "package_manager.state (its state assignment) and, to override the " &
            "companion library, package_manager.artifact"
        )
      block:
        let c = newCase()
        var dc = pmConfig()
        dc.orchestration.get.start = Opt.some(@[FakeInstance, PmInstance])
        check c.initPm(dc).refusedWith(
          "orchestration.start: package_manager is started by logosd itself; it is not " &
            "listed here"
        )
      block:
        let c = newCase()
        check c.initPm(pmConfig(pmSection(storageInstance = PmInstance))).refusedWith(
          "package_manager.storage: binding main names the Package Manager's own instance"
        )
      block:
        let c = newCase()
        var dc = pmConfig()
        dc.modules.get.add(hostedEntry("mine", "logos_mine", fakeLib, fakeRoot, "mine"))
        check c.initPm(dc).refusedWith(
          "modules: instance mine uses the reserved module-name prefix logos_"
        )
      # [G491] The shell cannot know which logosd starts: it composes a stand-in.
      let c = newCase()
      check c.initPm(pmConfig(pmSection(artifact = Opt.none(LcnAppArtifact)))).code == 0
      check c.ctl("daemon", "config", "check").code == 0
      let d = c.start()
      check waitExit(d, ReadyMs) == 1
      check "package_manager: this logosd has no Package Manager library; give " &
        "package_manager.artifact" in d.errText
      check hostsGone()
