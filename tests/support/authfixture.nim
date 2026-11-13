## Fixtures for the Capability Authority suites (step 8a; DECISIONS I84):
## a frozen clock, a facts table, a recording sink, policy and scope builders,
## and `openTest`.

import std/[atomics, os]
import results
import ../../src/logos_core/authority/[core, policy_types]
from ../../src/logos_core/runtime/rc_types import
  LogosNSRuntimeControlExecutionSelectionImplementationChoice,
  LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind,
  LogosNSRuntimeControlExecutionSelectionImplementationARDirectStaticMap,
  LogosNSRuntimeControlExecutionSelectionPackageMap,
  LogosNSRuntimeControlExecutionSelectionSignerMap

import ./slowdown

export core, policy_types, results, slowdown

const
  Rt* = "rt-1"
  Source* = "test-policy"

# Facts --------------------------------------------------------------------------

proc gammaSigner*(): seq[byte] =
  result = newSeq[byte](48)
  for i in 0 ..< 48:
    result[i] = byte(i + 1)

proc gammaSelection*(): ExecutionSelection =
  ExecutionSelection(
    implementation: LogosNSRuntimeControlExecutionSelectionImplementationChoice(
      kind:
        LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind.Direct_static,
      arm_Direct_static:
        LogosNSRuntimeControlExecutionSelectionImplementationARDirectStaticMap(),
    ),
    package: Opt.some(
      LogosNSRuntimeControlExecutionSelectionPackageMap(
        package: "pkg.gamma", version: "1.0.0"
      )
    ),
    signer: Opt.some(
      LogosNSRuntimeControlExecutionSelectionSignerMap(public_key: gammaSigner())
    ),
  )

proc fakeFacts*(runtimeId = Rt): SharedFacts =
  ## `m-a` (alpha), `m-b` (beta), `m-c` (gamma, signed and packaged), with
  ## providers `p-a` (m-a) and `p-b` (m-b).
  result = newSharedFacts(runtimeId)
  doAssert result.putInstance("m-a", InstanceFacts(module: "alpha")).isOk
  doAssert result.putInstance("m-b", InstanceFacts(module: "beta")).isOk
  doAssert result.putInstance(
    "m-c", InstanceFacts(module: "gamma", selection: Opt.some(gammaSelection()))
  ).isOk
  doAssert result.putProvider("p-a", "m-a").isOk
  doAssert result.putProvider("p-b", "m-b").isOk

func address*(instance: string, runtimeId = Rt): Address =
  Address(runtime_instance_id: runtimeId, module_instance_id: instance)

func moduleCaller*(instance: string, runtimeId = Rt): CallerInfo =
  CallerInfo(kind: ckModule, address: address(instance, runtimeId))

func systemCaller*(): CallerInfo =
  CallerInfo(kind: ckSystem)

# The recording sink ----------------------------------------------------------------

type
  SinkState = object
    ch: Channel[AuthorityEvent]
    failing: Atomic[bool]
    count: Atomic[int]
    order*: ptr Atomic[int] ## when set: `notifiedAt` takes the next value
    notifiedAt*: Atomic[int]
    hook*: proc(env: pointer) {.nimcall, gcsafe, raises: [].}
    hookEnv*: pointer

  ChannelSink* = ptr SinkState

proc sinkNotify(
    env: pointer, ev: sink AuthorityEvent
): bool {.nimcall, gcsafe, raises: [].} =
  let s = cast[ChannelSink](env)
  if s.failing.load:
    return false
  if s.order != nil:
    s.notifiedAt.store(s.order[].fetchAdd(1))
  if s.hook != nil:
    s.hook(s.hookEnv)
  try:
    s.ch.send(ev)
  except Exception:
    return false
  discard s.count.fetchAdd(1)
  true

proc newChannelSink*(): ChannelSink =
  result = cast[ChannelSink](allocShared0(sizeof(SinkState)))
  result.ch.open()

proc sink*(s: ChannelSink): AuthoritySink =
  AuthoritySink(env: s, notify: sinkNotify)

proc setFailing*(s: ChannelSink, failing: bool) =
  s.failing.store(failing)

proc count*(s: ChannelSink): int =
  s.count.load

proc drain*(s: ChannelSink): seq[AuthorityEvent] =
  while true:
    let (ok, ev) = s.ch.tryRecv()
    if not ok:
      break
    result.add ev

proc freeChannelSink*(s: ChannelSink) =
  ## Drains first: under ORC `close` frees the channel's buffer without
  ## destroying the events still queued in it.
  discard s.drain()
  s.ch.close()
  deallocShared(s)

# Policy builders -------------------------------------------------------------------

proc subject*(
    instances: seq[string] = @[],
    modules: seq[string] = @[],
    signers: seq[seq[byte]] = @[],
    packages: seq[string] = @[],
): LcnApSubject =
  if instances.len > 0:
    var x = instances
    sortSet(x)
    result.instances = Opt.some(x)
  if modules.len > 0:
    var x = modules
    sortSet(x)
    result.modules = Opt.some(x)
  if signers.len > 0:
    var x = signers
    sortSet(x)
    result.signers = Opt.some(x)
  if packages.len > 0:
    var x = packages
    sortSet(x)
    result.packages = Opt.some(x)

func anyone*(): LcnApSubject =
  LcnApSubject()

func targetSubject*(s: LcnApSubject): LcnApTarget =
  LcnApTarget(kind: LcnApTargetKind.lcn_Ap_subject, arm_lcn_Ap_subject: s)

func targetSelf*(): LcnApTarget =
  LcnApTarget(kind: LcnApTargetKind.Self)

func targetIssued*(): LcnApTarget =
  LcnApTarget(kind: LcnApTargetKind.Issued)

func declRoot*(root: seq[byte]): LcnApDecl =
  LcnApDecl(kind: LcnApDeclKind.Bstr, arm_Bstr: root)

func declName*(name: string): LcnApDecl =
  LcnApDecl(kind: LcnApDeclKind.Tstr, arm_Tstr: name)

proc decls*(xs: seq[LcnApDecl]): Opt[seq[LcnApDecl]] =
  var x = xs
  sortSet(x)
  Opt.some(x)

type ContractRef* = enum
  crExact
  crCa
  crRc

proc paPattern*(
    actions: seq[LcnApActionKind],
    contract = crExact,
    exact = SchemaCommitment(),
    providers = Opt.none(LcnApSubject),
    access = Opt.none(LcnApAccess),
): LcnApScope =
  var p = LcnApProviderAccess(providers: providers, access: access)
  p.contract =
    case contract
    of crExact:
      LcnApProviderAccessContractChoice(
        kind: LcnApProviderAccessContractChoiceKind.logos_Schema_commitment,
        arm_logos_Schema_commitment: exact,
      )
    of crCa:
      LcnApProviderAccessContractChoice(
        kind: LcnApProviderAccessContractChoiceKind.Capability_authority
      )
    of crRc:
      LcnApProviderAccessContractChoice(
        kind: LcnApProviderAccessContractChoiceKind.Runtime_control
      )
  for a in actions:
    p.actions.add LcnApAction(kind: a)
  sortSet(p.actions)
  LcnApScope(kind: LcnApScopeKind.lcn_Ap_provider_access, arm_lcn_Ap_provider_access: p)

proc rcPattern*(
    methods = Opt.none(seq[LcnApDecl]),
    events = Opt.none(seq[LcnApDecl]),
    targets = Opt.none(LcnApSubject),
): LcnApScope =
  LcnApScope(
    kind: LcnApScopeKind.lcn_Ap_runtime_control,
    arm_lcn_Ap_runtime_control:
      LcnApRuntimeControl(methods: methods, events: events, targets: targets),
  )

proc mePattern*(
    targets: LcnApSubject, actions: seq[LcnApModuleExecutionActionsLIChoiceKind]
): LcnApScope =
  var p = LcnApModuleExecution(targets: targets)
  for a in actions:
    p.actions.add LcnApModuleExecutionActionsLIChoice(kind: a)
  sortSet(p.actions)
  LcnApScope(
    kind: LcnApScopeKind.lcn_Ap_module_execution, arm_lcn_Ap_module_execution: p
  )

proc sorted*(xs: seq[LcnApScope]): seq[LcnApScope] =
  result = xs
  sortSet(result)

proc allowRule*(
    s: LcnApSubject, scopes: seq[LcnApScope], commitment = Opt.none(LcnApCommitment)
): LcnApRule =
  LcnApRule(
    kind: LcnApRuleKind.lcn_Ap_allow,
    arm_lcn_Ap_allow:
      LcnApAllow(subject: s, scopes: sorted(scopes), commitment: commitment),
  )

proc denyRule*(
    s: LcnApSubject, scopes: seq[LcnApScope], code = Opt.none(LcnApDenyCodeChoiceKind)
): LcnApRule =
  var d = LcnApDeny(subject: s, scopes: sorted(scopes))
  if code.isSome:
    d.code = Opt.some(LcnApDenyCodeChoice(kind: code.get))
  LcnApRule(kind: LcnApRuleKind.lcn_Ap_deny, arm_lcn_Ap_deny: d)

proc issueRule*(
    s: LcnApSubject,
    targets: LcnApTarget,
    scopes: seq[LcnApScope],
    maxValidityMs = Opt.none(uint64),
): LcnApRule =
  LcnApRule(
    kind: LcnApRuleKind.lcn_Ap_issue,
    arm_lcn_Ap_issue: LcnApIssue(
      subject: s,
      targets: targets,
      scopes: sorted(scopes),
      max_validity_ms: maxValidityMs,
    ),
  )

func revokeRule*(s: LcnApSubject, targets: LcnApTarget): LcnApRule =
  LcnApRule(
    kind: LcnApRuleKind.lcn_Ap_revoke,
    arm_lcn_Ap_revoke: LcnApRevoke(subject: s, targets: targets),
  )

func inspectRule*(
    s: LcnApSubject,
    grants = Opt.none(LcnApTarget),
    audit = Opt.none(LcnApTarget),
    policyChanges = false,
): LcnApRule =
  var r = LcnApInspect(subject: s, grants: grants, audit: audit)
  if policyChanges:
    r.policy_changes = Opt.some(true)
  LcnApRule(kind: LcnApRuleKind.lcn_Ap_inspect, arm_lcn_Ap_inspect: r)

proc policyValue*(
    rules: seq[LcnApRule],
    source = Source,
    validityMs = Opt.none(uint64),
    records = Opt.none(uint64),
): LcnAuthorityPolicy =
  var rs = rules
  sortSet(rs)
  result =
    LcnAuthorityPolicy(source: source, rules: rs, decision_validity_ms: validityMs)
  if records.isSome:
    result.audit = Opt.some(LcnAuthorityPolicyAuditMap(records: records))

proc policyBytes*(
    rules: seq[LcnApRule],
    source = Source,
    validityMs = Opt.none(uint64),
    records = Opt.none(uint64),
): seq[byte] =
  encode(policyValue(rules, source, validityMs, records)).expect("a valid policy")

# Scope builders ----------------------------------------------------------------------

proc testContract*(n: byte = 1): SchemaCommitment =
  var root = newSeq[byte](32)
  for i in 0 ..< 32:
    root[i] = n
  SchemaCommitment(schema_root: root)

proc root*(n: byte): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 32:
    result[i] = n

proc providerAddr*(p: string, runtimeId = Opt.none(string)): ProviderAddress =
  ProviderAddress(provider: p, runtime_instance_id: runtimeId)

proc access*(
    methods = Opt.none(seq[seq[byte]]),
    publish = Opt.none(seq[seq[byte]]),
    subscribe = Opt.none(seq[seq[byte]]),
): Opt[RouteAccess] =
  Opt.some(
    RouteAccess(methods: methods, publish_events: publish, subscribe_events: subscribe)
  )

proc pa*(
    actions: seq[PaActionKind],
    contract = testContract(),
    providers = Opt.none(seq[ProviderAddress]),
    routes = Opt.none(seq[string]),
    access = Opt.none(RouteAccess),
): Scope =
  var p = ProviderAccessScope(
    contract: contract, providers: providers, routes: routes, access: access
  )
  for a in actions:
    p.actions.add PaAction(kind: a)
  toScope(p)

proc callScope*(
    methodRoot: seq[byte], contract = testContract(), provider = "p-a", route = "r-1"
): Scope =
  pa(
    @[PaActionKind.Call],
    contract,
    Opt.some(@[providerAddr(provider)]),
    Opt.some(@[route]),
    access(methods = Opt.some(@[methodRoot])),
  )

proc meScope*(
    module: string,
    instance = Opt.none(string),
    action = MeActionKind.Start,
    package = Opt.none(string),
    version = Opt.none(string),
    runtimeId = Rt,
): Scope =
  toScope(
    ModuleExecutionScope(
      runtime: runtimeId,
      module: module,
      instance: instance,
      actions: @[MeAction(kind: action)],
      package: package,
      version: version,
    )
  )

func permissionScope*(name = "net"): Scope =
  toScope(PermissionScope(permission: name, constraints: @[0xA0'u8]))

func evalRequest*(
    consumer: string, scopes: seq[Scope], commitment = Opt.none(CommitmentRequirements)
): EvaluateRequest =
  EvaluateRequest(consumer: address(consumer), scopes: scopes, commitment: commitment)

# Opening ------------------------------------------------------------------------------

proc testConfig*(
    dir: string,
    policy: seq[byte],
    facts: SharedFacts,
    clock: Clock,
    sink: AuthoritySink,
    limits = AuthorityLimits(),
    runtimeId = Rt,
): AuthorityConfig =
  AuthorityConfig(
    stateDir: dir,
    policy: policy,
    runtimeId: runtimeId,
    facts: facts,
    clock: clock,
    limits: limits,
    sink: sink,
  )

proc openTest*(
    dir: string,
    policy: seq[byte],
    facts: SharedFacts,
    clock: Clock,
    sink: AuthoritySink,
    limits = AuthorityLimits(),
    runtimeId = Rt,
): Authority =
  openAuthority(testConfig(dir, policy, facts, clock, sink, limits, runtimeId)).expect(
    "opens"
  )

proc privateDir*(path: string) =
  ## A fresh, empty, owner-only directory.
  removeDir(path)
  createDir(path.parentDir)
