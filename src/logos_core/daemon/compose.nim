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
## | operator ones  | daemon-config `modules`      | `direct_dynamic` or `hosted_dynamic` | as configured |
##
## Under `capability-authority` logosd merges its system rules S1-S5 with the
## operator's into one `lcn.authority_policy`. They are derived from the
## reserved ids, not configurable, and listed in DAEMON.md §5.
##
## `prepareDaemon` runs DAEMON.md §3's five checks: the first four
## (`config.nim`) and the derived configuration through the library's own
## (`parseHostConfig`), plus the orchestrator's value through `validateSettings`.

{.push raises: [].}

import std/[algorithm, os, sets, strutils, tables]
import results
import logos_sdk/cbor
import ../loader/contract
from logos_sdk/abi/host import AppConfigFormat
from ../runtime/authscopes import AuthorityModule
from ../authority/scopes import rcContractInfo
from ../runtime/host_config import parseHostConfig
from ../permissions import HostAmbient
import ../orchestration/[settings, needs]
import ./[config, session, trustfile]

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
  RcEventPrefix = "logos.runtime_control."

type
  Composition* = object ## What logosd hands to the Runtime.
    appConfig*: LcnAppConfig ## the derived `lcn.app_config`
    bytes*: seq[byte] ## its deterministic CBOR
    orchestrator*: OrchestratorSettings ## the orchestration instance's value

  Prepared* = object ## A daemon-config that passed DAEMON.md §3's five checks.
    config*: DaemonConfig
    composition*: Composition

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

func denyRule(subject: CborValue, scopes: varargs[CborValue]): CborValue =
  cborMap(
    (t("kind"), t("deny")),
    (t("subject"), subject),
    (t("scopes"), cborArray(scopes)),
    (t("code"), t("target-denied")),
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

proc systemRules*(orch: OrchestratorSettings): Result[seq[CborValue], string] =
  ## [G295] S1 to S5 (DAEMON.md §5). Every start rule holds its execution
  ## scope and the host-ambient permission scope together (G207); an absent
  ## `modes` covers direct and hosted starts alike.
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
    rules.add denyRule(orchSubject, rcScope(newSeq[string](), Opt.some(unsubscribed)))
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
  rules.add denyRule(ctlSubject, rcScope(newSeq[string](), Opt.none(seq[string])))
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
  ok(rules)

proc mergedPolicy*(
    p: LcnDcPolicyARCapabilityAuthorityMap, orch: OrchestratorSettings
): Result[LcnAuthorityPolicy, string] =
  ## [G295] The operator's rules and options with the system rules, as one
  ## `lcn.authority_policy`, every array canonical.
  var rules = ?systemRules(orch)
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

func permissionsOf(dc: LcnDaemonConfig): LcnAppPermissions =
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

proc compose*(s: Session, c: DaemonConfig, exe = ""): Result[Composition, string] =
  ## [G294] The derived host configuration. `exe` is logosd's executable, for
  ## the default `module_host`; empty: none.
  let dc = c.value
  let orch = ?orchestratorValue(dc)
  var orchRecord =
    staticModule(OrchestratorInstance, OrchestratorModule, OrchestratorBinding)
  orchRecord.state_assignment = Opt.some(OrchestratorState)
  orchRecord.configuration = Opt.some(?orchestratorDeclaration())
  orchRecord.provisioned_configuration = Opt.some(?encodeSettings(orch))
  var modules = @[orchRecord, staticModule(CtlInstance, CtlModule, CtlBinding)]
  var policy = LcnAppPolicy(kind: LcnAppPolicyKind.Allow_all)
  if dc.policy.kind == LcnDcPolicyKind.Capability_authority:
    let p = dc.policy.arm_Capability_authority
    var ca = staticModule(AuthorityInstance, AuthorityModule, AuthorityModule)
    ca.state_assignment = Opt.some(AuthorityState)
    modules.add(ca)
    let merged = ?mergedPolicy(p, orch)
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
  var moduleHost = dc.runtime.module_host
  if moduleHost.isNone:
    moduleHost = defaultModuleHost(exe)
  let r = dc.runtime
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
    ),
    policy: policy,
    orchestration: OrchestratorInstance,
    modules: modules,
    ordering: dc.ordering,
    declarations: dc.declarations,
    routing: dc.routing,
    transport: dc.transport,
    permissions: Opt.some(permissionsOf(dc)),
    # [I96; G306; decision 9] The operator's transfers as they are: protected
    # offline input, applied once at the next start (DAEMON.md §11).
    state_transfers: dc.state_transfers,
  )
  if dc.call_audit.isSome:
    let a = dc.call_audit.get
    if a.call_records.isSome or a.evidence.isSome:
      app.call_audit =
        Opt.some(LcnAppCallAudit(call_records: a.call_records, evidence: a.evidence))
    else:
      app.call_audit = Opt.some(LcnAppCallAudit())
  let bytes = ?app.encode
  ok(Composition(appConfig: app, bytes: bytes, orchestrator: orch))

proc prepareDaemon*(
    s: Session,
    bytes: openArray[byte],
    trust: TrustInput,
    hooksBuild = HooksBuild,
    checkKey = true,
    exe = "",
): Result[Prepared, string] =
  ## DAEMON.md §3's checks 1 to 5 on daemon-config bytes, before anything
  ## starts; `logosctl daemon config check` runs the same.
  let dc = ?decodeDaemonConfig(bytes)
  let c = ?checkDaemonConfig(dc, trust, hooksBuild, checkKey)
  let comp = ?compose(s, c, exe)
  discard parseHostConfig(AppConfigFormat, comp.bytes).valueOr:
    return err("the derived host configuration is refused: " & error.message)
  ok(Prepared(config: c, composition: comp))

{.pop.}
