## RUNTIME §13.3; G76: `logos-core-nim.app-config.v1`, the one configuration
## format `logos_runtime_create` accepts. Its schema is `host_config.cddl`
## (generated codecs in `host_config_types.nim`); `docs/HOST-CONFIG.md`
## documents it, as RUNTIME l.4033 requires.
##
## Everything here runs at `create`: no file is opened, no thread started and no
## module code run. Every failure is INVALID_PARAMS (RUN-0741); only the two
## CBOR failures carry a `logos.invalid_params_detail`, since `schema-mismatch`
## names a request schema and `configuration-schema-mismatch` CONFIG's
## (INTERFACE l.3351-3355), and the detail is optional.

{.push raises: [].}

import std/[os, sets, strutils, tables, times]
import results
import ../cbor
import ../iface/outcome
import ../abi/host
import ./[artifact, plumbing]
import ./host_config_types
from ../authority/policy import loadPolicy
from ./authscopes import AuthorityModule, caRoots

export results

const
  MinDeadlineMs* = 1'u32 ## [IMPL] the shortest deadline the format accepts
  MaxDeadlineMs* = 3_600_000'u32 ## [IMPL] the longest: one hour
  MaxEvaluationDeadlineMs* = 60_000'u32
    ## [IMPL] the longest evaluation deadline: one minute (DECISIONS I85)

type
  HostModule* = object
    instance*: string ## the protected module instance identity
    record*: ModuleRecord

  EvidenceKeySetting* = object
    ## [SPEC CA §9.1] The call-evidence signing key's configuration; `create`
    ## reads the file (`host.nim`, `evidence.loadEvidenceKey`).
    kid*: seq[byte] ## `logos.capability_authority.evidence_key_id`
    secretKeyFile*: string

  HostConfig* = object ## A decoded and validated `lcn.app_config`.
    workDir*: string
    stateRoot*: Opt[string]
    storeDir*: Opt[string] ## [IMPL] the persistent Runtime state (I82)
    runtimeInstanceId*: string ## [G192 interim (TF-27)] empty: the store's own identity
    startupDeadline*: Duration
    stopDeadline*: Duration
    shutdownGrace*: Duration
    policy*: AuthzPolicy ## the internal policy: allow-all
    authority*: Opt[AuthorityPolicy]
      ## [I85] `capability-authority`: the instance whose binding decides
    authorityPolicy*: seq[byte]
      ## [I85; C9] its `lcn.authority_policy`, as deterministic CBOR, for the
      ## authority's wiring
    callRecords*: int ## [I85] the call-record ring's capacity
    callAudit*: bool ## [I85] `call_audit` is configured
    evidence*: Opt[EvidenceKeySetting]
    orchestration*: string ## [G53] the instance holding the orchestration role
    modules*: seq[HostModule] ## in configuration order
    ordering*: seq[(string, string)] ## (prerequisite, dependent), RUNTIME §3.7
    declarations*: seq[ModuleDeclaration] ## [G55] what `create_module` may create

  ConfigError* = object
    message*: string
    detail*: Opt[seq[byte]] ## an encoded `logos.invalid_params_detail`

func configError(message: string): ConfigError =
  ConfigError(message: message)

func checkPath(name, p: string): Result[void, ConfigError] =
  ## [IMPL] Absolute, so the meaning does not depend on the host's working
  ## directory. (Logos text holds no NUL, so the schema has refused a path a C
  ## call would cut short.)
  if not p.isAbsolute:
    return err(configError(name & " must be an absolute path"))
  ok()

func deadline(
    name: string, ms: Opt[uint32], default: Duration
): Result[Duration, ConfigError] =
  if ms.isNone:
    return ok(default)
  let v = ms.get
  if v < MinDeadlineMs or v > MaxDeadlineMs:
    return err(configError(name & " must be 1 to 3600000 milliseconds"))
  ok(initDuration(milliseconds = int64(v)))

func within(path, dir: string): bool =
  ## `path` is `dir` or below it, lexically.
  let p = normalizedPath(path)
  let d = normalizedPath(dir)
  p == d or p.startsWith(d.strip(leading = false, chars = {'/'}) & "/")

func checkStore(c: HostConfig): Result[void, ConfigError] =
  ## [IMPL] The store directory holds `runtime-state.cbor`, its side records
  ## and `lock`, so no module state or artifact copy may land in it (I82).
  ## Without one nothing persists, and a configured identity would repeat
  ## addresses and revisions across starts (RUN-0632).
  if c.storeDir.isNone:
    if c.runtimeInstanceId.len > 0:
      return err(configError("runtime_instance_id needs store_dir"))
    return ok()
  let s = c.storeDir.get
  ?checkPath("store_dir", s)
  if within(s, c.workDir) or within(c.workDir, s):
    return err(configError("store_dir and work_dir must be apart"))
  if c.stateRoot.isSome and (within(s, c.stateRoot.get) or within(c.stateRoot.get, s)):
    return err(configError("store_dir and state_root must be apart"))
  ok()

func rootOf(c: SchemaCommitment): Digest =
  ## The schema checked `schema_root` as a 32-byte string.
  var d: Digest
  for i in 0 ..< d.len:
    d[i] = c.schema_root[i]
  d

func record(m: LcnAppModule | LcnAppDeclaration): Result[ModuleRecord, ConfigError] =
  ## The resolved module record a configured module or a declaration stands
  ## for (RUNTIME §8).
  var r = ModuleRecord(module: m.module)
  when m is LcnAppModule:
    r.stateAssignment = m.state_assignment
  case m.implementation.kind
  of LcnAppImplementationKind.Direct_static:
    r.strategy = stDirectStatic
    r.binding = m.implementation.arm_Direct_static.binding
  of LcnAppImplementationKind.Direct_dynamic:
    let a = m.implementation.arm_Direct_dynamic.artifact
    ?checkPath("an artifact local_path", a.local_path)
    r.strategy = stDirectDynamic
    var hash: array[32, byte]
    for i in 0 ..< hash.len:
      hash[i] = a.hash[i]
    r.artifact = ArtifactRecord(
      id: a.id, localPath: a.local_path, hash: hash, hashSuite: a.hash_suite
    )
  if m.primary_contract.isSome:
    r.primaryContract = Opt.some(rootOf(m.primary_contract.get))
  # [SPEC RUNTIME §8 l.1428] A present array is non-empty.
  if m.implements.isSome:
    if m.implements.get.len == 0:
      return err(configError("implements is present but empty"))
    for c in m.implements.get:
      r.implements.add(rootOf(c))
  if m.requires.isSome:
    if m.requires.get.len == 0:
      return err(configError("requires is present but empty"))
    for q in m.requires.get:
      r.requires.add(
        ProviderRequirement(
          contract: rootOf(q.contract),
          cardinality:
            case q.cardinality.kind
            of LcnAppRequirementCardinalityChoiceKind.Single:
              cardSingle
            of LcnAppRequirementCardinalityChoiceKind.All_runtime_visible:
              cardAllVisible,
        )
      )
  if m.requested_permissions.isSome:
    if m.requested_permissions.get.len == 0:
      return err(configError("requested_permissions is present but empty"))
    for p in m.requested_permissions.get:
      r.requestedPermissions.add(
        RequestedPermission(
          permission: p.permission, constraints: p.constraints, reason: p.reason
        )
      )
  checkRecord(r).isOkOr:
    return err(configError(error))
  ok(r)

func checkOrdering(c: HostConfig, ids: HashSet[string]): Result[void, ConfigError] =
  ## [SPEC RUNTIME §3.7] Every constraint names listed instances and the
  ## constraints form no cycle. [IMPL] Nothing starts the orchestration
  ## instance's prerequisites before bootstrap (there is no Loader or CA module
  ## to), so it is never a dependent.
  var
    indegree = initTable[string, int]()
    next = initTable[string, seq[string]]()
  for (pre, dep) in c.ordering:
    if pre notin ids or dep notin ids:
      return err(configError("an ordering constraint names an instance not in modules"))
    if pre == dep:
      return err(configError("an ordering constraint names one instance twice"))
    if dep == c.orchestration:
      return
        err(configError("the orchestration instance cannot be an ordering dependent"))
    next.mgetOrPut(pre, @[]).add(dep)
    indegree.mgetOrPut(dep, 0).inc
  var ready: seq[string]
  for id in ids:
    if indegree.getOrDefault(id) == 0:
      ready.add(id)
  var seen = 0
  while ready.len > 0:
    let id = ready.pop()
    inc seen
    for d in next.getOrDefault(id):
      let left = indegree.getOrDefault(d) - 1
      indegree[d] = left
      if left == 0:
        ready.add(d)
  if seen != ids.len:
    return err(configError("the ordering constraints form a cycle"))
  ok()

func cborFailure(e: CborError): ConfigError =
  let reason =
    case e.kind
    of cekNonDeterministic:
      Opt.some(iprNonDeterministicCbor)
    of cekMalformed, cekInvalidUtf8:
      Opt.some(iprMalformedCbor)
    of cekTooDeep:
      Opt.none(outcome.InvalidParamsReason)
  ConfigError(
    message: "the configuration is not one deterministic-CBOR value: " & $e,
    detail:
      if reason.isSome:
        Opt.some(invalidParamsDetail(reason.get))
      else:
        Opt.none(seq[byte]),
  )

proc checkAuthority(
    c: var HostConfig, p: LcnAppPolicyARCapabilityAuthorityMap
): Result[void, ConfigError] =
  ## [I85; plan §3.2] The `capability-authority` policy's checks at `create`.
  var found = false
  var r: ModuleRecord
  for m in c.modules:
    if m.instance == p.authority:
      found = true
      r = m.record
  if not found:
    return err(configError("policy.authority names no instance in modules"))
  # [SPEC CA l.143] The Capability Authority's module. A configured module is
  # direct_static or direct_dynamic, so a local module instance (CAP-0003,
  # CAP-0006).
  if r.module != AuthorityModule:
    return err(configError("policy.authority's module is not " & AuthorityModule))
  # [IMPL] The authority is the Capability Authority this library links (8a),
  # wired in process (RUNTIME l.1681): its `direct_static` binding
  # `logos_capability_authority`, which the library registers itself, since a
  # host-registered table cannot use the reserved `logos` names (I84). A
  # library loaded apart would not see the wiring.
  if r.strategy != stDirectStatic or r.binding != AuthorityModule:
    return err(
      configError(
        "policy.authority must be the direct_static binding " & AuthorityModule
      )
    )
  # [SPEC RUNTIME l.1652-1655; RUN-0316] Otherwise checked at binding.
  if r.primaryContract.isSome and @(r.primaryContract.get) != caRoots().contract:
    return err(
      configError(
        "policy.authority's primary_contract is not the pinned Capability Authority contract"
      )
    )
  # [SPEC RUNTIME l.1637] A candidate does not bind or authorize itself: the
  # authority is never the orchestration instance, whose module name is outside
  # the reserved prefix (checked above).
  # [C8] The authority keeps grants and audit in its state; the Runtime keeps
  # its identity, so decisions and grants name the same Runtime across starts.
  if c.storeDir.isNone:
    return err(configError("capability-authority needs store_dir"))
  if r.stateAssignment.isNone:
    return err(configError("the authority instance needs a state_assignment"))
  if c.stateRoot.isNone:
    return err(configError("capability-authority needs state_root"))
  var deadline = DefaultEvaluationDeadline
  if p.evaluation_deadline_ms.isSome:
    let v = p.evaluation_deadline_ms.get
    if v < MinDeadlineMs or v > MaxEvaluationDeadlineMs:
      return err(configError("evaluation_deadline_ms must be 1 to 60000 milliseconds"))
    deadline = initDuration(milliseconds = int64(v))
  # [C34(a)] An evaluation never outlasts the start it decides.
  if deadline >= c.startupDeadline:
    return err(configError("evaluation_deadline_ms must be below startup_deadline_ms"))
  # [C9] 8a's policy format, checked as the authority will load it.
  let bytes = encodeCbor(toCbor(p.policy))
  discard loadPolicy(bytes).valueOr:
    return err(configError(error))
  c.authority = Opt.some(
    AuthorityPolicy(
      instance: p.authority,
      evaluationDeadline: deadline,
      recovery: p.recovery.get(false),
    )
  )
  c.authorityPolicy = bytes
  ok()

proc checkCallAudit(c: var HostConfig, a: LcnAppCallAudit): Result[void, ConfigError] =
  ## [I85; plan §3.2] `call_audit` (CA §9, §9.1).
  c.callAudit = true
  if a.call_records.isSome:
    let v = a.call_records.get
    if v < 1 or v > uint32(MaxCallRecords):
      return err(configError("call_audit.call_records must be 1 to 1000000"))
    c.callRecords = int(v)
  if a.evidence.isSome:
    let k = a.evidence.get
    ?checkPath("call_audit.evidence.secret_key_file", k.secret_key_file)
    # [C8] Evidence names this Runtime, so its identity persists.
    if c.storeDir.isNone:
      return err(configError("call_audit.evidence needs store_dir"))
    c.evidence =
      Opt.some(EvidenceKeySetting(kid: k.kid, secretKeyFile: k.secret_key_file))
  ok()

proc decodeHostConfig*(
    format: string, data: openArray[byte]
): Result[HostConfig, ConfigError] =
  ## [SPEC RUNTIME §13.3] Decodes and validates one configuration; RUN-0741.
  ## Every check, without `parseHostConfig`'s refusal of what is not built
  ## yet: for tests of the checks themselves.
  if format != AppConfigFormat:
    return err(configError("unsupported configuration format"))
  # [SPEC RUNTIME §8 l.1410-1411] One deterministic-CBOR value, nothing after it.
  let v = decodeCbor(data).valueOr:
    return err(cborFailure(error))
  # [S5] Name an unknown policy kind before the schema's generic answer.
  let policy = v.lookup("policy")
  if policy.isSome:
    let kind = policy.get.lookup("kind")
    if kind.isSome and kind.get.kind == ckText and
        kind.get.text notin ["allow-all", "capability-authority"]:
      return err(configError("this policy kind is not supported yet"))
  let cfg = LcnAppConfig.fromCbor(v).valueOr:
    return err(configError("the configuration does not match lcn.app_config: " & error))
  var c = HostConfig(
    workDir: cfg.runtime.work_dir,
    stateRoot: cfg.runtime.state_root,
    storeDir: cfg.runtime.store_dir,
    runtimeInstanceId: cfg.runtime.runtime_instance_id.get(""),
    policy: allowAll(),
    orchestration: cfg.orchestration,
    callRecords: DefaultCallRecords,
  )
  ?checkPath("work_dir", c.workDir)
  if c.stateRoot.isSome:
    ?checkPath("state_root", c.stateRoot.get)
  ?checkStore(c)
  c.startupDeadline = ?deadline(
    "startup_deadline_ms", cfg.runtime.startup_deadline_ms, DefaultStartupDeadline
  )
  c.stopDeadline =
    ?deadline("stop_deadline_ms", cfg.runtime.stop_deadline_ms, DefaultStopDeadline)
  c.shutdownGrace =
    ?deadline("shutdown_grace_ms", cfg.runtime.shutdown_grace_ms, DefaultShutdownGrace)
  if cfg.modules.len == 0:
    return err(configError("modules is empty"))
  var
    ids = initHashSet[string]()
    assignments = initHashSet[string]()
  for m in cfg.modules:
    let r = record(m).valueOr:
      return err(configError("module instance " & m.instance & ": " & error.message))
    if m.instance in ids:
      return err(configError("module instance " & m.instance & " is listed twice"))
    ids.incl(m.instance)
    if isRuntimeForm(m.instance) or
        (r.stateAssignment.isSome and isRuntimeForm(r.stateAssignment.get)):
      # [IMPL] Names of this form are the Runtime's own (I82).
      return err(
        configError(
          "module instance " & m.instance & " uses a Runtime-assigned name form"
        )
      )
    if r.stateAssignment.isSome:
      # [SPEC RUNTIME §8 l.1451] Distinct instances do not share one.
      if r.stateAssignment.get in assignments:
        return err(configError("two module instances share a state assignment"))
      assignments.incl(r.stateAssignment.get)
    c.modules.add(HostModule(instance: m.instance, record: r))
  # [G53] The role is named explicitly, on a listed instance whose module name
  # is outside the reserved prefix; no name confers it (RUN-0784, RUN-0785).
  var orchestrationModule = ""
  for m in c.modules:
    if m.instance == c.orchestration:
      orchestrationModule = m.record.module
  if orchestrationModule.len == 0:
    return err(configError("orchestration names no instance in modules"))
  if orchestrationModule.startsWith("logos_"):
    return err(
      configError(
        "the orchestration instance's module name is in the reserved logos_ prefix"
      )
    )
  if cfg.ordering.isSome:
    if cfg.ordering.get.len == 0:
      return err(configError("ordering is present but empty"))
    for o in cfg.ordering.get:
      c.ordering.add((o.prerequisite, o.dependent))
  ?checkOrdering(c, ids)
  if cfg.declarations.isSome:
    # [G55] One accepted declaration per module name (RUNTIME l.3614).
    if cfg.declarations.get.len == 0:
      return err(configError("declarations is present but empty"))
    var modules = initHashSet[string]()
    for d in cfg.declarations.get:
      let r = record(d).valueOr:
        return err(configError("declaration " & d.module & ": " & error.message))
      if d.module in modules:
        return err(configError("module " & d.module & " is declared twice"))
      modules.incl(d.module)
      let persistent = d.persistent_state.get(false)
      if persistent and c.stateRoot.isNone:
        return err(
          configError("declaration " & d.module & ": persistent_state needs state_root")
        )
      c.declarations.add(ModuleDeclaration(record: r, persistentState: persistent))
  case cfg.policy.kind
  of LcnAppPolicyKind.Allow_all:
    discard
  of LcnAppPolicyKind.Capability_authority:
    ?checkAuthority(c, cfg.policy.arm_Capability_authority)
  if cfg.call_audit.isSome:
    ?checkCallAudit(c, cfg.call_audit.get)
  ok(c)

proc parseHostConfig*(
    format: string, data: openArray[byte]
): Result[HostConfig, ConfigError] =
  ## [SPEC RUNTIME §13.3] Decodes and validates one configuration; RUN-0741.
  ## [I85] Every kind the format has is built (8b-3), so nothing is refused
  ## beyond `decodeHostConfig`'s checks.
  decodeHostConfig(format, data)
