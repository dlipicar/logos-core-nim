## logosd's composition and bootstrap (Tier 4b step 4b-6; DECISIONS G294,
## G295; BCP l.287-291, l.360). docs/DAEMON.md §4 and §5.
##
## `compose` is a pure function from a checked daemon-config to the one
## `logos-core-nim.app-config.v1` value logosd hands to `logos_runtime_create`.
## The Module Loader is not in it: the engine establishes
## `logos_module_loader` itself before the open answers (G246), and every
## instance below is realized by it (BCP-0021 to BCP-0024).
##
## | Instance       | Module                       | Implementation                     | State |
## |----------------|------------------------------|------------------------------------|-------|
## | `orchestrator` | `lcn_orchestrator`           | `direct_static` `lcn_orchestrator` | `orchestrator` |
## | `authority`    | `logos_capability_authority` | the library's static binding       | `authority` (capability-authority only) |
## | `logosctl`     | `logosctl`                   | `direct_static` `logosctl`         | none |
## | `lcn_call`     | `lcn_call`                   | `hosted_dynamic` (process), the companion library | none |
## | `package_manager` | `logos_package_manager`   | `hosted_dynamic` (process), the companion library | `package_manager.state` |
## | operator ones  | daemon-config `modules`      | `direct_dynamic` or `hosted_dynamic` | as configured |
##
## `lcn_call`, the CLI module (Tier 5 step N-2; G343), is composed when its
## artifact is known: daemon-config `cli.artifact`, else the library installed
## with logosd at `<d>/../lib/logos-core/`, whose BLAKE3-256 is compiled in
## (`-d:lcnCallArtifactHash=<hex>`). It is not in the start list: the first
## launcher starts it (DAEMON.md §7a).
##
## `package_manager`, the Package Manager (Tier 5 step 5-6a-1; G491, C1), is
## composed with a `package_manager` section: from `package_manager.artifact`,
## else the companion `liblogos_package_manager` installed with logosd, whose
## BLAKE3-256 is compiled in (`-d:pmArtifactHash=<hex>`); with neither the start
## is refused. logosctl's checks (`init`, `daemon config check` and `set`) cannot
## know which logosd will start: they compose a stand-in at the companion
## library's place (`pmCompanion`), as they assume test hooks (G300), and the
## start decides. Its state assignment is `package_manager.state`, its permissions
## host-ambient, and the host configuration's `package_manager` mark names it
## (G490). logosd adds it to the orchestrator's start list after the operator's,
## so rule S2 covers its start.
##
## Under `capability-authority` logosd merges its system rules S1-S12 with the
## operator's into one `lcn.authority_policy`. They are derived from the
## reserved ids, not configurable, and listed in DAEMON.md §5; S6-S8 only
## when `lcn_call` is composed, S9-S12 only with a `package_manager` section.
##
## `prepareDaemon` runs DAEMON.md §3's five checks: the first four
## (`config.nim`) and the derived configuration through the library's own
## (`parseHostConfig`), plus the orchestrator's value through `validateSettings`.

{.push raises: [].}

import std/[algorithm, os, sequtils, sets, strutils, tables]
import results
import logos_sdk/cbor
from logos_sdk/cbor/encode import cmpBytes
import ../loader/contract
from logos_sdk/base/hex import fromHex
from logos_sdk/abi/host import AppConfigFormat
from ../runtime/authscopes import AuthorityModule
from ../authority/scopes import rcContractInfo
from ../runtime/host_config import parseHostConfig
from ../permissions import HostAmbient
from ../transport/tls/trustsnap import TrustSnapshot, newTrustSnapshot
import ../remote/carrier
from logos_sdk/pins import CommitmentModelId, HashProfileId, HashSuiteId
import logos_sdk/contracts/generated/lcn_storage_fetch_root
import ../orchestration/[settings, needs]
import ../cli/callsettings
from ../pm/contractset import pmContractSet
import ./[config, remoteexposure, session, trustfile]

when defined(posix):
  import std/posix

export results, config

const
  PolicyFormat* = "logos-core-nim.authority-policy.v1"
  PermissionProfileId* = "logos-core-nim.permission-profile.v1"
  DefaultPolicySource* = "logosd-default" ## [G295] `logosctl init`'s policy source
  AmbientConstraints* = [0xA0'u8] ## host-ambient's constraints: the empty map
  OrchestratorState* = "orchestrator"
  AuthorityState* = "authority"
  ModuleHostName* = "logos-module-host" ## [G264]
  LibexecHost* = ".." / "libexec" / "logos-core" / ModuleHostName
  RemoteProgramName* = "logos_remote" ## [G411]
  LibexecRemote* = ".." / "libexec" / "logos-core" / RemoteProgramName
  LibDir* = ".." / "lib" / "logos-core" ## [G343] the companion library's directory
  CliLibrary* = DynlibFormat.replace("$1", CliModule) ## `liblcn_call.so` or `.dylib`
  PmLibrary* = DynlibFormat.replace("$1", PmModule)
    ## [G491] `liblogos_package_manager.so` or `.dylib`
  PmArtifactId* = PmModule ## [G491] the composed artifact's id
  RcEventPrefix = "logos.runtime_control."
  lcnCallArtifactHash* {.strdefine.} = ""
    ## [G343 Q3 (a)] BLAKE3-256 of the companion `liblcn_call`, in hex, compiled
    ## into a packaged logosd; empty: only `cli.artifact` composes lcn_call
  CliMethods* = [
    "get_self", "list_modules", "describe_provider", "establish_route", "renew_route",
    "close_route",
  ] ## [G345] S6: what the lcn_call instance may call
  CliEvents* = ["module_state_changed", "execution_state_changed", "inventory_changed"]
    ## [G346] the events rule: the events `logosctl events` follows by default

const pmArtifactHash* {.strdefine.} = ""
  ## [G491] BLAKE3-256 of the companion `liblogos_package_manager`, in hex,
  ## compiled into a packaged logosd; empty: only `package_manager.artifact`
  ## composes the Package Manager

const PmCompanion* = pmArtifactHash.len > 0
  ## [G491] This build composes the Package Manager from its companion library
  ## when `package_manager.artifact` is absent; a test logosd and logosctl never do

static:
  doAssert lcnCallArtifactHash.len in [0, 64],
    "lcnCallArtifactHash is 64 hex digits (BLAKE3-256)"
  doAssert pmArtifactHash.len in [0, 64], "pmArtifactHash is 64 hex digits (BLAKE3-256)"

type
  Composition* = object ## What logosd hands to the Runtime.
    appConfig*: LcnAppConfig ## the derived `lcn.app_config`
    bytes*: seq[byte] ## its deterministic CBOR
    orchestrator*: OrchestratorSettings ## the orchestration instance's value
    retained*: Retained
      ## [G412; Q4] the durable disables applied to the records, and those
      ## dropped, which the start removes from the file

  RemoteSeen* = object
    ## [G408, G412] What this start read of the remote inputs, for compose:
    ## the trust snapshot the remote processes take, and the durable disables
    ## (`state/remote-exposure.cbor`, Q4).
    snapshot*: TrustSnapshot
    exposure*: seq[LcnRemoteExposureEntry]

  Prepared* = object ## A daemon-config that passed DAEMON.md §3's five checks.
    config*: DaemonConfig
    composition*: Composition
    policyReport*: seq[string]
      ## [G415] the authority policy's load report, which logosd logs

# CBOR helpers for the policy -------------------------------------------------------

func t(s: string): CborValue =
  cbor(s)

func texts(xs: openArray[string]): CborValue =
  var a = newCborArray(xs.len)
  for i, x in xs:
    a.items[i] = cbor(x)
  a

func subjectOf(field: string, xs: openArray[string]): CborValue =
  cborMap((t(field), texts(xs)))

func canonical(v: CborValue): CborValue =
  ## Every array of a policy is a set (AUTHORITY-POLICY.md): ascending by its
  ## items' deterministic-CBOR bytes, without duplicates.
  case v.kind
  of ckArray:
    var items: seq[(seq[byte], CborValue)]
    for x in v.items:
      let c = canonical(x)
      items.add((encodeCbor(c), c))
    items.sort(
      proc(a, b: (seq[byte], CborValue)): int =
        cmpBytes(a[0], b[0])
    )
    var a = newCborArray(0)
    for i, x in items:
      if i > 0 and x[0] == items[i - 1][0]:
        continue
      a.items.add(x[1])
    a
  of ckMap:
    var entries: seq[CborEntry]
    for e in v.entries:
      entries.add((e.key, canonical(e.value)))
    cborMap(entries)
  else:
    v

func rule(kind: string, subject: CborValue, scopes: varargs[CborValue]): CborValue =
  cborMap(
    (t("kind"), t(kind)), (t("subject"), subject), (t("scopes"), cborArray(scopes))
  )

func denyRule(code: string, subject: CborValue, scopes: varargs[CborValue]): CborValue =
  ## [G295; G377] A deny rule states its code: `consumer-denied` when it
  ## denies the consumer an action, `target-denied` when every pattern names
  ## the target it protects (CA l.783-784).
  cborMap(
    (t("kind"), t("deny")),
    (t("subject"), subject),
    (t("scopes"), cborArray(scopes)),
    (t("code"), t(code)),
  )

func rcScope(
    methods: openArray[string], events: Opt[seq[string]], targets = Opt.none(CborValue)
): CborValue =
  var entries: seq[CborEntry] =
    @[(t("kind"), t("runtime-control")), (t("methods"), texts(methods))]
  if events.isSome:
    entries.add((t("events"), texts(events.get)))
  if targets.isSome:
    entries.add((t("targets"), targets.get))
  cborMap(entries)

func execScope(targets: CborValue, actions: openArray[string]): CborValue =
  cborMap(
    (t("kind"), t("module-execution")),
    (t("targets"), targets),
    (t("actions"), texts(actions)),
  )

func ambientScope(): CborValue =
  ## [G207; G110] host-ambient, with any conforming constraints.
  cborMap((t("kind"), t("permission")), (t("permission"), t(HostAmbient)))

func bareEvent(name: string): string =
  ## A Runtime Control event's name as a policy names it: without the
  ## namespace and the `_event` suffix (AUTHORITY-POLICY.md, "Names and roots").
  var n = name
  if n.startsWith(RcEventPrefix):
    n = n[RcEventPrefix.len .. ^1]
  if n.endsWith("_event"):
    n = n[0 ..< n.len - "_event".len]
  n

# The system rules -------------------------------------------------------------------

func storageFetchContract(): CborValue =
  ## [G402] `lcn.storage_fetch`'s schema commitment, as a policy names it.
  cborMap(
    (t("commitment_model"), t(CommitmentModelId)),
    (t("schema_root"), cbor(@LcnStorageFetchRoot)),
    (t("hash_profile"), t(HashProfileId)),
    (t("hash_suite"), t(HashSuiteId)),
  )

proc pmContract(): Result[CborValue, string] =
  ## [G503] The composed Package Manager's primary contract, as a policy names it.
  let cs = pmContractSet().valueOr:
    return err("package_manager: the pinned Package Manager contract: " & error)
  ok(
    cborMap(
      (t("commitment_model"), t(CommitmentModelId)),
      (t("schema_root"), cbor(@(cs.primary.root))),
      (t("hash_profile"), t(HashProfileId)),
      (t("hash_suite"), t(HashSuiteId)),
    )
  )

func roots(xs: openArray[array[32, byte]]): CborValue =
  ## Declaration roots as a policy set: strictly ascending (AUTHORITY-POLICY.md).
  var sorted = xs.mapIt(@it)
  sorted.sort(
    proc(a, b: seq[byte]): int =
      cmpBytes(a, b)
  )
  var a = newCborArray(0)
  for x in sorted:
    a.items.add(cbor(x))
  a

proc systemRules*(
    orch: OrchestratorSettings, cli = false, pm = Opt.none(PmSettings)
): Result[seq[CborValue], string] =
  ## [G295] S1 to S5 (DAEMON.md §5), and S6 to S8 when the lcn_call instance
  ## is composed (`cli`; G345, G346). Every start rule holds its execution scope and
  ## the host-ambient permission scope together (G207); an absent `modes`
  ## covers direct and hosted starts alike.
  ## [G402] S9 to S11 with a `package_manager` section (`pm`); [G491] S12 too;
  ## [G503] S13 too, and S14 when lcn_call is composed as well.
  ## The composed Package Manager's start is S2's: `orchestratorValue` puts it in
  ## the orchestrator's start list, so its needs include it.
  let n = ?orchestratorNeeds(orch)
  var rules: seq[CborValue]
  # S1: the authority publishes its change notices.
  rules.add rule(
    "allow",
    subjectOf("modules", [AuthorityModule]),
    cborMap(
      (t("kind"), t("provider-access")),
      (t("contract"), t("capability-authority")),
      (t("actions"), texts(["publish-event"])),
      (t("access"), cborMap((t("publish_events"), texts(["observed_change"])))),
    ),
  )
  # S2: the orchestration module's calls and events (P5), and the executions
  # it originates, each with host-ambient.
  var methods = n.everyInstance
  var starts, stops: seq[string]
  for o in n.origins:
    if o.methodName == "stop_module":
      stops.add(o.instance)
    else:
      starts.add(o.instance)
  methods.add("start_module")
  if stops.len > 0:
    methods.add("stop_module")
  var events: seq[string]
  for e in n.events:
    events.add(bareEvent(e))
  # A method request carries no event list, so a pattern that lists events
  # never covers it (CA l.126; `policy.listCovers`); an absent `events` covers
  # every subscription too, so the events the module does not subscribe to
  # are denied (an event request names no method: methods [] , events [e]).
  var unsubscribed: seq[string]
  for name in rcContractInfo().events.keys:
    if name notin events:
      unsubscribed.add(name)
  let orchSubject = subjectOf("instances", [OrchestratorInstance])
  rules.add rule("allow", orchSubject, rcScope(methods, Opt.none(seq[string])))
  if unsubscribed.len > 0:
    rules.add denyRule(
      "consumer-denied", orchSubject, rcScope(newSeq[string](), Opt.some(unsubscribed))
    )
  if starts.len > 0:
    rules.add rule(
      "allow",
      orchSubject,
      execScope(subjectOf("instances", starts), ["start"]),
      ambientScope(),
    )
  if stops.len > 0:
    rules.add rule(
      "allow", orchSubject, execScope(subjectOf("instances", stops), ["stop"])
    )
  # S3: logosctl's Runtime Control (decision 9; G82, without `evaluate`), no
  # event subscription (denied, as for S2), and the executions it originates,
  # with host-ambient.
  let ctlSubject = subjectOf("instances", [CtlInstance])
  rules.add rule("allow", ctlSubject, rcScope(CtlMethods, Opt.none(seq[string])))
  rules.add denyRule(
    "consumer-denied", ctlSubject, rcScope(newSeq[string](), Opt.none(seq[string]))
  )
  rules.add rule(
    "allow", ctlSubject, execScope(cborMap(), ["start", "stop"]), ambientScope()
  )
  # S4: the shell cannot stop, restart, retire or reconfigure the bootstrap
  # services or its own instance; the Loader stays a denied target (P6-47).
  # A lifecycle request names its target's module, and the CA contains a
  # request naming modules only in a modules-only `targets` subject
  # (`policy.patternContains`), so the Runtime Control denies name the
  # reserved modules; check 2 keeps every instance of them a system one.
  let system =
    subjectOf("instances", [LoaderInstanceId, AuthorityInstance, CtlInstance])
  let systemModules =
    subjectOf("modules", [LoaderModuleName, AuthorityModule, CtlModule])
  rules.add denyRule(
    "target-denied",
    ctlSubject,
    rcScope(
      [
        "start_module", "stop_module", "recover_module", "retire_module",
        "update_configuration", "apply_configuration",
      ],
      Opt.none(seq[string]),
      Opt.some(systemModules),
    ),
    execScope(system, ["start", "stop"]),
  )
  # S5: orchestration is restored only by recover_module (R l.3808), and
  # configured only by daemon-config.
  let orchTarget = subjectOf("instances", [OrchestratorInstance])
  rules.add denyRule(
    "target-denied",
    ctlSubject,
    rcScope(
      [
        "start_module", "stop_module", "retire_module", "update_configuration",
        "apply_configuration",
      ],
      Opt.none(seq[string]),
      Opt.some(subjectOf("modules", [OrchestratorModule])),
    ),
    execScope(orchTarget, ["stop"]),
  )
  if cli:
    # S6: lcn_call's Runtime Control, as a consumer: discovery and routes. A
    # method list with no event list covers every subscription too (as in S2).
    let cliSubject = subjectOf("instances", [CliInstance])
    rules.add rule("allow", cliSubject, rcScope(CliMethods, Opt.none(seq[string])))
    # S7: of the events, only those `events` follows by default (an event
    # request names no method: methods [], events [e]); and no execution.
    var otherEvents: seq[string]
    for name in rcContractInfo().events.keys:
      if name notin CliEvents:
        otherEvents.add(name)
    otherEvents.sort() # the listing in DAEMON.md §5 does not follow a table's order
    if otherEvents.len > 0:
      rules.add denyRule(
        "consumer-denied", cliSubject, rcScope(newSeq[string](), Opt.some(otherEvents))
      )
    rules.add denyRule(
      "consumer-denied", cliSubject, execScope(cborMap(), ["start", "stop"])
    )
    # S8: the shell cannot reconfigure or retire lcn_call; it may start, stop
    # and recover it (the activation, DAEMON.md §7a).
    rules.add denyRule(
      "target-denied",
      ctlSubject,
      rcScope(
        ["retire_module", "update_configuration", "apply_configuration"],
        Opt.none(seq[string]),
        Opt.some(subjectOf("modules", [CliModule])),
      ),
    )
  if pm.isSome:
    # [G402] The Package Manager's routes to its Storage providers, which are
    # ordinary module routes: logosd issues each and decides its Hello.
    let pmSubject = subjectOf("instances", [pm.get.instance])
    # A subject's list is a set: each provider once, ascending.
    var named = pm.get.providers.toHashSet.toSeq
    named.sort()
    let providers = subjectOf("instances", named)
    # S9 (the first three): the Runtime Control methods that hold a route,
    # and `list_modules` (a route names a provider record, not an instance),
    # no Runtime Control event (as S3), and the route and the three calls.
    # The Runtime Control rule names no `targets`: `establish_route` and a
    # list decide with no target, `renew_route` and `close_route` name a route,
    # and this authority never narrows an allow (AUTHORITY-POLICY.md; CA l.124
    # permits it, nothing requires it), so a targeted rule would allow none of
    # them. The provider-access rule names the providers.
    rules.add rule(
      "allow",
      pmSubject,
      rcScope(
        ["close_route", "establish_route", "list_modules", "renew_route"],
        Opt.none(seq[string]),
      ),
    )
    rules.add denyRule(
      "consumer-denied", pmSubject, rcScope(newSeq[string](), Opt.none(seq[string]))
    )
    rules.add rule(
      "allow",
      pmSubject,
      cborMap(
        (t("kind"), t("provider-access")),
        (t("contract"), storageFetchContract()),
        (t("actions"), texts(["call", "establish-route", "renew-route"])),
        (t("providers"), providers),
        (
          t("access"),
          cborMap(
            (
              t("methods"),
              roots(
                [
                  LcnStorageFetchStatObjectRoot, LcnStorageFetchReadObjectRoot,
                  LcnStorageFetchFetchReadinessRoot,
                ]
              ),
            )
          ),
        ),
      ),
    )
    # S10: its subscription to fetch_readiness_changed on those routes.
    rules.add rule(
      "allow",
      pmSubject,
      cborMap(
        (t("kind"), t("provider-access")),
        (t("contract"), storageFetchContract()),
        (t("actions"), texts(["subscribe-event"])),
        (t("providers"), providers),
        (
          t("access"),
          cborMap((t("subscribe_events"), roots([LcnStorageFetchReadinessChangedRoot]))),
        ),
      ),
    )
    # S11: the providers publish that event (STORAGE-FETCH §8).
    rules.add rule(
      "allow",
      providers,
      cborMap(
        (t("kind"), t("provider-access")),
        (t("contract"), storageFetchContract()),
        (t("actions"), texts(["publish-event"])),
        (
          t("access"),
          cborMap((t("publish_events"), roots([LcnStorageFetchReadinessChangedRoot]))),
        ),
      ),
    )
    # S12 [G491]: as S8 for lcn_call, the shell may start, stop and recover the
    # composed Package Manager, and cannot retire or reconfigure it.
    rules.add denyRule(
      "target-denied",
      ctlSubject,
      rcScope(
        ["retire_module", "update_configuration", "apply_configuration"],
        Opt.none(seq[string]),
        Opt.some(subjectOf("modules", [PmModule])),
      ),
    )
    # S13 [G503]: the Package Manager publishes its two events,
    # installed_packages_changed and operation_progress (PM §15.1, §15.2), each
    # to the readers its own scope names.
    let contract = ?pmContract()
    rules.add rule(
      "allow",
      pmSubject,
      cborMap(
        (t("kind"), t("provider-access")),
        (t("contract"), contract),
        (t("actions"), texts(["publish-event"])),
      ),
    )
    if cli:
      # S14 [G503]: lcn_call discovers the composed Package Manager, holds routes
      # to it, calls its eight methods, mutations included (the owner's Q14 (a),
      # 2026-11-23), and subscribes to its two events. Whether a list or a watch
      # is answered is the Package Manager's own check (`readers`, G498). A
      # discovery names a contract and no provider (`engine.describeProvider`), so
      # a pattern with `providers` never covers it: the rule's first pattern allows
      # it on the contract, the second the rest at the Package Manager only; each
      # requested scope needs one of them (G207).
      rules.add rule(
        "allow",
        subjectOf("instances", [CliInstance]),
        cborMap(
          (t("kind"), t("provider-access")),
          (t("contract"), contract),
          (t("actions"), texts(["discover"])),
        ),
        cborMap(
          (t("kind"), t("provider-access")),
          (t("contract"), contract),
          (
            t("actions"),
            texts(["call", "establish-route", "renew-route", "subscribe-event"]),
          ),
          (t("providers"), pmSubject),
        ),
      )
  ok(rules)

proc mergedPolicy*(
    p: LcnDcPolicyARCapabilityAuthorityMap,
    orch: OrchestratorSettings,
    cli = false,
    pm = Opt.none(PmSettings),
): Result[LcnAuthorityPolicy, string] =
  ## [G295] The operator's rules and options with the system rules, as one
  ## `lcn.authority_policy`, every array canonical.
  var rules = ?systemRules(orch, cli, pm)
  for r in p.rules:
    rules.add(toCbor(r))
  var entries: seq[CborEntry] = @[
    (t("format"), t(PolicyFormat)),
    (t("source"), t(p.source)),
    (t("rules"), cborArray(rules)),
  ]
  if p.decision_validity_ms.isSome:
    entries.add((t("decision_validity_ms"), cbor(p.decision_validity_ms.get)))
  if p.audit.isSome:
    entries.add((t("audit"), toCbor(p.audit.get)))
  let v = canonical(cborMap(entries))
  LcnAuthorityPolicy.fromCbor(v).mapErr(
    proc(e: string): string =
      "policy: the merged policy does not match lcn.authority_policy: " & e
  )

# The orchestration module's value ---------------------------------------------------

proc orchestratorValue*(dc: LcnDaemonConfig): Result[OrchestratorSettings, string] =
  ## [decision 8; G294] The authority (under capability-authority), logosctl
  ## and the operator's start list as `defaults`; the operator's ordering, the
  ## same pairs as the host configuration's (G287); the restart policy.
  var s = OrchestratorSettings()
  if dc.policy.kind == LcnDcPolicyKind.Capability_authority:
    s.authority = Opt.some(
      LcnOrchestratorTarget(module: AuthorityModule, instance: AuthorityInstance)
    )
  var defaults = @[LcnOrchestratorDefault(module: CtlModule, instance: CtlInstance)]
  if dc.orchestration.isSome:
    for id in dc.orchestration.get.start.get(@[]):
      var module = ""
      for m in dc.modules.get(@[]):
        if m.instance == id:
          module = m.module
      defaults.add(LcnOrchestratorDefault(module: module, instance: id))
  if dc.package_manager.isSome:
    # [G491] The composed Package Manager starts with no operator entry, after
    # the operator's list; S2 derives its start's authorization from this value.
    defaults.add(LcnOrchestratorDefault(module: PmModule, instance: PmInstance))
  s.defaults = Opt.some(defaults)
  if dc.ordering.isSome:
    var pairs: seq[LcnOrchestratorOrder]
    for o in dc.ordering.get:
      pairs.add(
        LcnOrchestratorOrder(prerequisite: o.prerequisite, dependent: o.dependent)
      )
    s.ordering = Opt.some(pairs)
  if dc.orchestration.isSome:
    let o = dc.orchestration.get
    if o.restart.isSome:
      s.restart = Opt.some(
        ?LcnOrchestratorRestart.fromCbor(toCbor(o.restart.get)).mapErr(
          proc(e: string): string =
            "orchestration.restart: " & e
        )
      )
    if o.overrides.isSome:
      var xs: seq[LcnOrchestratorOverride]
      for v in o.overrides.get:
        xs.add(
          ?LcnOrchestratorOverride.fromCbor(toCbor(v)).mapErr(
            proc(e: string): string =
              "orchestration.overrides: " & e
          )
        )
      s.overrides = Opt.some(xs)
    s.resync_ms = o.resync_ms
  validateSettings(s).isOkOr:
    return err("orchestration: " & error)
  ok(s)

# Permissions ------------------------------------------------------------------------

func ambient(): LcnAppPermissionSetting =
  LcnAppPermissionSetting(permission: HostAmbient, constraints: @AmbientConstraints)

func permissionsOf(dc: LcnDaemonConfig, cli: bool): LcnAppPermissions =
  ## [G491] The composed Package Manager gets host-ambient too.
  ## [G294; decision 3; G110, G284] The reference profile unless one is named;
  ## the operator's entries; host-ambient for each system instance; and, for
  ## each operator module the operator gave no module entry, the module entry
  ## host-ambient, the minimum every realization needs (G280).
  var initial: seq[LcnAppInitialSettings]
  var named = initHashSet[string]()
  if dc.permissions.isSome and dc.permissions.get.initial.isSome:
    for e in dc.permissions.get.initial.get:
      initial.add(e)
      if e.instance.isNone:
        named.incl(e.module)
  initial.add(
    LcnAppInitialSettings(
      module: OrchestratorModule,
      instance: Opt.some(OrchestratorInstance),
      permissions: @[ambient()],
    )
  )
  initial.add(
    LcnAppInitialSettings(
      module: CtlModule, instance: Opt.some(CtlInstance), permissions: @[ambient()]
    )
  )
  if cli:
    initial.add(
      LcnAppInitialSettings(
        module: CliModule, instance: Opt.some(CliInstance), permissions: @[ambient()]
      )
    )
  if dc.package_manager.isSome:
    initial.add(
      LcnAppInitialSettings(
        module: PmModule, instance: Opt.some(PmInstance), permissions: @[ambient()]
      )
    )
  if dc.policy.kind == LcnDcPolicyKind.Capability_authority:
    initial.add(
      LcnAppInitialSettings(
        module: AuthorityModule,
        instance: Opt.some(AuthorityInstance),
        permissions: @[ambient()],
      )
    )
  var modules: seq[string]
  for m in dc.modules.get(@[]):
    modules.add(m.module)
  for d in dc.declarations.get(@[]):
    modules.add(d.module)
  for m in modules:
    if not named.containsOrIncl(m):
      initial.add(LcnAppInitialSettings(module: m, permissions: @[ambient()]))
  LcnAppPermissions(profile: PermissionProfileId, initial: Opt.some(initial))

# The host program -------------------------------------------------------------------

proc realPath(p: string): string =
  when defined(posix):
    var buf: array[4096, char]
    if realpath(cstring(p), cast[cstring](addr buf[0])) != nil:
      return $cast[cstring](addr buf[0])
  p

proc defaultModuleHost*(exe: string): Opt[string] =
  ## [G294; C17] `<d>/../libexec/logos-core/logos-module-host`, else
  ## `<d>/logos-module-host`, where `<d>` is the directory of logosd's own
  ## executable after its links are resolved, so a Nix profile's link resolves
  ## into the store path. None when neither exists.
  if exe.len == 0:
    return Opt.none(string)
  let d = realPath(exe).parentDir
  for candidate in [d / LibexecHost, d / ModuleHostName]:
    let p = candidate.normalizedPath
    if fileExists(p):
      return Opt.some(realPath(p))
  Opt.none(string)

proc defaultRemoteProgram*(exe: string): Opt[string] =
  ## [G411] `logos_remote`, found as `defaultModuleHost` finds the Module Host.
  if exe.len == 0:
    return Opt.none(string)
  let d = realPath(exe).parentDir
  for candidate in [d / LibexecRemote, d / RemoteProgramName]:
    let p = candidate.normalizedPath
    if fileExists(p):
      return Opt.some(realPath(p))
  Opt.none(string)

proc companionLibrary*(exe: string, library = CliLibrary): Opt[string] =
  ## [G343] `<d>/../lib/logos-core/liblcn_call.{so,dylib}`, `<d>` as for the
  ## Module Host; none when `exe` is empty. [G491] `library` names another
  ## companion library there (`PmLibrary`).
  if exe.len == 0:
    return Opt.none(string)
  Opt.some((realPath(exe).parentDir / LibDir / library).normalizedPath)

proc cliArtifact*(c: DaemonConfig, exe: string): Opt[LcnAppArtifact] =
  ## [G343] `cli.artifact`, else the companion library with the compiled hash;
  ## none: this logosd composes no lcn_call.
  if c.cli.artifact.isSome:
    return c.cli.artifact
  when lcnCallArtifactHash.len == 0:
    Opt.none(LcnAppArtifact)
  else:
    let path = companionLibrary(exe).valueOr:
      return Opt.none(LcnAppArtifact)
    let hash = hex.fromHex(lcnCallArtifactHash).valueOr:
      return Opt.none(LcnAppArtifact)
    Opt.some(LcnAppArtifact(id: LcnCallArtifactId, local_path: path, hash: hash))

proc pmArtifact*(c: DaemonConfig, exe: string): Opt[LcnAppArtifact] =
  ## [G491] `package_manager.artifact`, else the companion library with the
  ## compiled hash; none: this logosd cannot compose the Package Manager.
  if c.pm.isNone:
    return Opt.none(LcnAppArtifact)
  if c.pm.get.artifact.isSome:
    return c.pm.get.artifact
  when pmArtifactHash.len == 0:
    Opt.none(LcnAppArtifact)
  else:
    let path = companionLibrary(exe, PmLibrary).valueOr:
      return Opt.none(LcnAppArtifact)
    let hash = hex.fromHex(pmArtifactHash).valueOr:
      return Opt.none(LcnAppArtifact)
    Opt.some(LcnAppArtifact(id: PmArtifactId, local_path: path, hash: hash))

proc standInPmArtifact(exe: string): LcnAppArtifact =
  ## [G491] What logosctl's checks compose for the companion library: its place
  ## beside `exe` (an absolute path whatever `exe` is) and an all-zero digest. It
  ## is only checked, never started.
  let path =
    companionLibrary(exe, PmLibrary).get("/" & "lib" / "logos-core" / PmLibrary)
  LcnAppArtifact(id: PmArtifactId, local_path: path, hash: newSeq[byte](32))

func pmRecord(
    pm: PmSettings, artifact: LcnAppArtifact, root: openArray[byte]
): LcnAppModule =
  ## [G491] The Package Manager instance: hosted in its own process (C1), its
  ## primary contract PM App A (`root`, so that the Runtime gives it a provider
  ## record, RUNTIME l.2862-2871), its state assignment `package_manager.state`,
  ## no configuration (its input is protected, G400), no `requires` or
  ## `requested_permissions`.
  LcnAppModule(
    instance: PmInstance,
    module: PmModule,
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Process_hosted_dynamic,
      arm_Process_hosted_dynamic:
        LcnAppImplementationARProcessHostedDynamicMap(artifact: artifact),
    ),
    primary_contract: Opt.some(SchemaCommitment(schema_root: @root)),
    state_assignment: Opt.some(pm.state),
  )

func cliSocketPath*(s: Session, socketDir: string): string =
  ## [G344] `run/lcn_call.sock`, or in `cli.socket_dir`; logosctl's launcher
  ## reads the same rule.
  (if socketDir.len > 0: socketDir else: s.runDir) / CliSocketName

func cliSocketPath*(s: Session, c: DaemonConfig): string =
  cliSocketPath(s, c.cli.socketDir)

proc cliRecord(
    s: Session, c: DaemonConfig, artifact: LcnAppArtifact
): Result[LcnAppModule, string] =
  ## [G343] The lcn_call instance: hosted, its settings provisioned.
  let settings = LcnCallSettings(
    socket: cliSocketPath(s, c),
    deployment: LcnCallSettingsDeploymentChoice(
      kind:
        if c.production:
          LcnCallSettingsDeploymentChoiceKind.Production
        else:
          LcnCallSettingsDeploymentChoiceKind.Non_production
    ),
    workers: uint8(c.cli.workers),
    streams: uint8(c.cli.streams),
    idle_timeout_ms: uint32(c.cli.idleTimeoutMs),
    route_idle_ms: uint32(c.cli.routeIdleMs),
  )
  let declaration = ?lcnCallDeclaration()
  let provisioned = ?encodeSettings(settings)
  ok(
    LcnAppModule(
      instance: CliInstance,
      module: CliModule,
      implementation: LcnAppImplementation(
        kind: LcnAppImplementationKind.Process_hosted_dynamic,
        arm_Process_hosted_dynamic:
          LcnAppImplementationARProcessHostedDynamicMap(artifact: artifact),
      ),
      configuration: Opt.some(declaration),
      provisioned_configuration: Opt.some(provisioned),
    )
  )

proc pmInputOf(
    c: DaemonConfig, cliComposed: bool, modules: openArray[LcnAppModule]
): Result[seq[byte], string] =
  ## [IMPL-DECISION G399, G498] The composed `lcn.pm_input`: the checked section's,
  ## with its readers (C4) and the Runtime their calls come from. Without
  ## `package_manager.readers` the reader is `lcn_call` when this start composes it,
  ## and there is none when it does not; a listed reader is an instance this start
  ## runs, never the Package Manager itself.
  let dc = c.value
  let given = dc.package_manager.get.readers
  var readers: seq[string]
  if given.isSome:
    var running = initHashSet[string]()
    for m in modules:
      running.incl(m.instance)
    var seen = initHashSet[string]()
    for r in given.get:
      if seen.containsOrIncl(r):
        return err("package_manager.readers names " & r & " twice")
      if r == PmInstance:
        return err("package_manager.readers names the Package Manager's own instance")
      if r notin running:
        return err(
          "package_manager.readers names " & r &
            ", which is not an instance this start runs"
        )
      readers.add(r)
  elif cliComposed:
    readers = @[CliInstance]
  let v = decodeCbor(c.pm.get.input).valueOr:
    return err("package_manager: the composed input does not decode: " & $error)
  var entries = v.entries
  if readers.len > 0:
    var items: seq[CborValue]
    for r in readers:
      items.add(cbor(r))
    entries.add((cbor("readers"), CborValue(kind: ckArray, items: items)))
  entries.add((cbor("runtime_instance_id"), cbor(dc.runtime.runtime_instance_id)))
  ok(encodeCbor(cborMap(entries)))

proc protectedInputsOf(
    c: DaemonConfig, cliComposed: bool, modules: openArray[LcnAppModule]
): Result[Opt[seq[LcnAppProtectedInput]], string] =
  ## [IMPL-DECISION G399, G400] With `package_manager`, its instance's
  ## `lcn.pm_input`, the one protected realization input logosd writes.
  if c.pm.isNone:
    return ok(Opt.none(seq[LcnAppProtectedInput]))
  let input = ?pmInputOf(c, cliComposed, modules)
  ok(Opt.some(@[LcnAppProtectedInput(instance: c.pm.get.instance, input: input)]))

# Composition ------------------------------------------------------------------------

func staticModule(instance, module, binding: string): LcnAppModule =
  LcnAppModule(
    instance: instance,
    module: module,
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_static,
      arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
    ),
  )

proc remoteValue*(
    c: DaemonConfig, seen: Opt[RemoteSeen]
): Result[(Opt[LcnAppRemote], Retained), string] =
  ## [G408, G412] The host configuration's `remote`, with `remote.enabled`:
  ## this start's trust snapshot, as the remote processes take it, and the
  ## deployment's records with the retained disables whose configuration
  ## entry is unchanged applied (Q4). Without what the start read (a check
  ## before it, `logosctl daemon config check`) the snapshot is an empty one
  ## and nothing is retained, so the records are still checked.
  if not c.remote.enabled:
    return ok((Opt.none(LcnAppRemote), Retained()))
  let t =
    if seen.isSome:
      seen.get.snapshot
    else:
      ?newTrustSnapshot(0, [], [])
  var x = c.value.remote.get
  var retained = Retained()
  if seen.isSome:
    retained = ?applyRetained(x, seen.get.exposure)
  let snapshot = ?snapshotMessage(t).encode
  ok(
    (
      Opt.some(
        LcnAppRemote(snapshot: snapshot, listeners: x.listeners, exports: x.exports)
      ),
      retained,
    )
  )

proc compose*(
    s: Session,
    c: DaemonConfig,
    exe = "",
    remote = Opt.none(RemoteSeen),
    pmCompanion = PmCompanion,
): Result[Composition, string] =
  ## [G294] The derived host configuration. `exe` is logosd's executable, for
  ## the default `module_host` and `remote_program`; empty: none. `remote` is
  ## what this start read of the remote inputs (G408), with `remote.enabled`.
  ## `pmCompanion` (G491): the logosd that will start has the companion Package
  ## Manager library; true from logosctl, which composes a stand-in for it.
  let dc = c.value
  let orch = ?orchestratorValue(dc)
  var orchRecord =
    staticModule(OrchestratorInstance, OrchestratorModule, OrchestratorBinding)
  orchRecord.state_assignment = Opt.some(OrchestratorState)
  orchRecord.configuration = Opt.some(?orchestratorDeclaration())
  orchRecord.provisioned_configuration = Opt.some(?encodeSettings(orch))
  var modules = @[orchRecord, staticModule(CtlInstance, CtlModule, CtlBinding)]
  let cliArt = cliArtifact(c, exe)
  if cliArt.isSome:
    modules.add(?cliRecord(s, c, cliArt.get))
  var policy = LcnAppPolicy(kind: LcnAppPolicyKind.Allow_all)
  if dc.policy.kind == LcnDcPolicyKind.Capability_authority:
    let p = dc.policy.arm_Capability_authority
    var ca = staticModule(AuthorityInstance, AuthorityModule, AuthorityModule)
    ca.state_assignment = Opt.some(AuthorityState)
    modules.add(ca)
    let merged = ?mergedPolicy(p, orch, cliArt.isSome, c.pm)
    policy = LcnAppPolicy(
      kind: LcnAppPolicyKind.Capability_authority,
      arm_Capability_authority: LcnAppPolicyARCapabilityAuthorityMap(
        authority: AuthorityInstance,
        policy: merged,
        evaluation_deadline_ms: p.evaluation_deadline_ms,
        recovery: p.recovery,
      ),
    )
  for m in dc.modules.get(@[]):
    modules.add(m)
  var pmMark = Opt.none(string)
  if c.pm.isSome:
    # [G491] With neither `package_manager.artifact` nor a companion library hash,
    # logosd cannot compose the section. logosctl, built without the hash, checks
    # with a stand-in at the companion's place: the start decides.
    var art = pmArtifact(c, exe)
    if art.isNone and pmCompanion:
      art = Opt.some(standInPmArtifact(exe))
    if art.isNone:
      return err(
        "package_manager: this logosd has no Package Manager library; give " &
          "package_manager.artifact"
      )
    let contract = pmContractSet().valueOr:
      return err("package_manager: the pinned Package Manager contract: " & error)
    modules.add(pmRecord(c.pm.get, art.get, contract.primary.root))
    pmMark = Opt.some(PmInstance)
  # [IMPL-DECISION G505] logosd's own composed instances, never an operator's,
  # may take a new library hash at a start (a logosd upgrade, an override):
  # each keeps its state and grants. Their ids are checked (`checkCli`,
  # `checkPackageManager`), and every other fact still has to be equal.
  var adoption: seq[string]
  if cliArt.isSome:
    adoption.add(CliInstance)
  if pmMark.isSome:
    adoption.add(PmInstance)
  var moduleHost = dc.runtime.module_host
  if moduleHost.isNone:
    moduleHost = defaultModuleHost(exe)
  let r = dc.runtime
  var remoteProgram = r.remote_program
  if c.remote.enabled and remoteProgram.isNone:
    remoteProgram = defaultRemoteProgram(exe)
  let protectedInputs = ?protectedInputsOf(c, cliArt.isSome, modules)
  var app = LcnAppConfig(
    runtime: LcnAppRuntime(
      work_dir: s.workDir,
      state_root: Opt.some(s.modulesDir),
      store_dir: Opt.some(s.storeDir),
      runtime_instance_id: Opt.some(r.runtime_instance_id),
      startup_deadline_ms: r.startup_deadline_ms,
      stop_deadline_ms: r.stop_deadline_ms,
      shutdown_grace_ms: r.shutdown_grace_ms,
      apply_deadline_ms: r.apply_deadline_ms,
      max_payload_depth: r.max_payload_depth,
      endpoint_dir: Opt.some(s.endpointDir),
      module_host: moduleHost,
      module_host_env: r.module_host_env,
      remote_program: remoteProgram,
    ),
    policy: policy,
    orchestration: OrchestratorInstance,
    modules: modules,
    protected_inputs: protectedInputs,
    ordering: dc.ordering,
    declarations: dc.declarations,
    routing: dc.routing,
    transport: dc.transport,
    permissions: Opt.some(permissionsOf(dc, cliArt.isSome)),
    # [I96; G306; decision 9] The operator's transfers as they are: protected
    # offline input, applied once at the next start (DAEMON.md §11).
    state_transfers: dc.state_transfers,
    package_manager: pmMark,
    artifact_adoption:
      (if adoption.len > 0: Opt.some(adoption)
      else: Opt.none(seq[string])),
  )
  if dc.call_audit.isSome:
    let a = dc.call_audit.get
    if a.call_records.isSome or a.evidence.isSome:
      app.call_audit =
        Opt.some(LcnAppCallAudit(call_records: a.call_records, evidence: a.evidence))
    else:
      app.call_audit = Opt.some(LcnAppCallAudit())
  let (remoteApp, retained) = ?remoteValue(c, remote)
  app.remote = remoteApp
  let bytes = ?app.encode
  ok(Composition(appConfig: app, bytes: bytes, orchestrator: orch, retained: retained))

proc prepareDaemon*(
    s: Session,
    bytes: openArray[byte],
    trust: TrustFileState,
    hooksBuild = HooksBuild,
    checkKey = true,
    exe = "",
    remote = Opt.none(RemoteSeen),
    pmCompanion = PmCompanion,
): Result[Prepared, string] =
  ## DAEMON.md §3's checks 1 to 5 on daemon-config bytes, before anything
  ## starts; `logosctl daemon config check` runs the same. `remote` is what
  ## the start read of the remote inputs (G408), passed on to the remote
  ## processes. `pmCompanion` as for `compose`.
  let dc = ?decodeDaemonConfig(bytes)
  let c = ?checkDaemonConfig(dc, trust, hooksBuild, checkKey)
  let comp = ?compose(s, c, exe, remote, pmCompanion)
  let hc = parseHostConfig(AppConfigFormat, comp.bytes).valueOr:
    return err("the derived host configuration is refused: " & error.message)
  ok(Prepared(config: c, composition: comp, policyReport: hc.policyReport))

{.pop.}
