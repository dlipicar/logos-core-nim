## The Capability Authority's policy: load, validate, resolve, match [IMPL]
## (BCP l.359-360; CA §5, §6, §10; DECISIONS I84; docs/AUTHORITY-POLICY.md).
##
## The input is one deterministic-CBOR `lcn.authority_policy` value
## (`policy.cddl`). Loading checks what the schema cannot express and resolves
## every name to an exact root, so evaluation sees only exact roots and no
## alias survives load (CA l.451-452).
##
## Rules have no order. Deny overrides allow.

{.push raises: [].}

import std/[sets, strutils, tables]
import results
import ../cbor
import ../crypto/blake3
import ./[facts, policy_types, scopes]

export results, facts, scopes

const
  DefaultValidityMs* = 3_600_000'u64
  MinValidityMs* = 1_000'u64
  MaxValidityMs* = 86_400_000'u64
  DefaultAuditRecords* = 65_536'u64
  MinAuditRecords* = 1_024'u64
  MaxAuditRecords* = 1_048_576'u64

type
  Subject* = object
    ## Fields AND, entries OR; `{}` matches any Runtime-known instance (G47).
    instances*: Opt[seq[string]]
    modules*: Opt[seq[string]]
    signers*: Opt[seq[seq[byte]]]
    packages*: Opt[seq[string]]

  TargetKind* = enum
    tkSubject
    tkSelf
    tkIssued

  Target* = object
    kind*: TargetKind
    subject*: Subject

  PatternKind* = enum
    pkProvider
    pkControl
    pkExecution

  Pattern* = object
    case kind*: PatternKind
    of pkProvider:
      contract*: SchemaCommitment
      paActions*: set[PaActionKind]
      providers*: Opt[Subject]
      access*: Opt[RouteAccess]
    of pkControl:
      methods*, events*: Opt[seq[Root]]
      targets*: Opt[Subject]
    of pkExecution:
      execTargets*: Subject
      meActions*: set[MeActionKind]
      modes*: Opt[set[ExecModeKind]]
      placements*: Opt[set[PlacementKind]]

  RuleKind* = enum
    rkAllow
    rkDeny
    rkIssue
    rkRevoke
    rkInspect

  Rule* = object
    subject*: Subject
    case kind*: RuleKind
    of rkAllow:
      allow*: seq[Pattern]
      commitment*: Opt[CommitmentRequirements]
    of rkDeny:
      deny*: seq[Pattern]
      code*: DenialKind
    of rkIssue:
      issueTargets*: Target
      issue*: seq[Pattern]
      maxValidityMs*: Opt[uint64]
    of rkRevoke:
      revokeTargets*: Target
    of rkInspect:
      grants*: Opt[Target]
      audit*: Opt[Target]
      policyChanges*: bool

  Policy* = object
    bytes*: seq[byte]
    digest*: seq[byte] ## BLAKE3-256 of `bytes`
    source*: string ## the protected-policy issuer source (CA l.696)
    validityMs*: uint64
    auditRecords*: uint64
    rules*: seq[Rule]

  FactsSnapshot* = object
    ## The facts of an instance when a grant or record was made: historical
    ## addresses are filtered with it (CA l.78-79). It never authenticates
    ## anything (l.80).
    instance*: string
    module*: string
    signer*: Opt[seq[byte]]
    package*: Opt[string]

# The rule enums mirror the scope enums name for name.
template sameEnum(A, B: typedesc) =
  static:
    doAssert ord(high(A)) == ord(high(B))
    for x in A:
      doAssert $x == $B(ord(x)), $x

sameEnum(LcnApActionKind, PaActionKind)
sameEnum(LcnApModuleExecutionActionsLIChoiceKind, MeActionKind)
sameEnum(LcnApModuleExecutionModesLIChoiceKind, ExecModeKind)
sameEnum(LcnApModuleExecutionPlacementsLIChoiceKind, PlacementKind)

# Facts ------------------------------------------------------------------------------

func snapshot*(instance: string, f: InstanceFacts): FactsSnapshot =
  FactsSnapshot(
    instance: instance, module: f.module, signer: f.signer, package: f.package
  )

func matches*(s: Subject, f: FactsSnapshot): bool =
  if s.instances.isSome and f.instance notin s.instances.get:
    return false
  if s.modules.isSome and f.module notin s.modules.get:
    return false
  if s.signers.isSome and (f.signer.isNone or f.signer.get notin s.signers.get):
    return false
  if s.packages.isSome and (f.package.isNone or f.package.get notin s.packages.get):
    return false
  true

func modulesOnly(s: Subject): bool =
  s.modules.isSome and s.instances.isNone and s.signers.isNone and s.packages.isNone

# Loading ----------------------------------------------------------------------------

func validSource*(s: string): bool =
  ## [SPEC CA l.696] `[a-z0-9][a-z0-9._-]{0,127}` [IMPL pattern].
  if s.len < 1 or s.len > 128:
    return false
  for i, c in s:
    if c in {'a' .. 'z', '0' .. '9'}:
      continue
    if i > 0 and c in {'.', '_', '-'}:
      continue
    return false
  true

proc setOf[T](xs: openArray[T], nonEmpty: bool, what: string): Result[void, string] =
  if nonEmpty and xs.len == 0:
    return err(what & " is empty")
  if not isSet(xs):
    return err(what & " is not a set (strictly ascending, no duplicates)")
  ok()

proc setOf[T](xs: Opt[seq[T]], nonEmpty: bool, what: string): Result[void, string] =
  if xs.isSome:
    ?setOf(xs.get, nonEmpty, what)
  ok()

proc compileSubject(s: LcnApSubject, what: string): Result[Subject, string] =
  ?setOf(s.instances, true, what & ".instances")
  ?setOf(s.modules, true, what & ".modules")
  ?setOf(s.signers, true, what & ".signers")
  ?setOf(s.packages, true, what & ".packages")
  ok(
    Subject(
      instances: s.instances,
      modules: s.modules,
      signers: s.signers,
      packages: s.packages,
    )
  )

proc compileTarget(
    t: LcnApTarget, issuedAllowed: bool, what: string
): Result[Target, string] =
  case t.kind
  of LcnApTargetKind.Self:
    ok(Target(kind: tkSelf))
  of LcnApTargetKind.Issued:
    if not issuedAllowed:
      return err(what & ": \"issued\" is valid only in revoke and inspect rules")
    ok(Target(kind: tkIssued))
  of LcnApTargetKind.lcn_Ap_subject:
    let subject = ?compileSubject(t.arm_lcn_Ap_subject, what)
    ok(Target(kind: tkSubject, subject: subject))

proc resolveDecls(
    xs: Opt[seq[LcnApDecl]],
    names: Table[string, Root],
    symbolic: bool,
    events: bool,
    what: string,
): Result[Opt[seq[Root]], string] =
  if xs.isNone:
    return ok(Opt.none(seq[Root]))
  ?setOf(xs.get, false, what)
  var roots: seq[Root]
  for d in xs.get:
    case d.kind
    of LcnApDeclKind.Bstr:
      roots.add d.arm_Bstr
    of LcnApDeclKind.Tstr:
      if not symbolic:
        return err(what & ": a declaration name needs a symbolic contract")
      let name =
        if events:
          eventName(d.arm_Tstr)
        else:
          d.arm_Tstr
      if name notin names:
        return err(what & ": unknown declaration " & d.arm_Tstr)
      roots.add names.getOrDefault(name)
  # The resolved list is matched as a set: duplicates after resolution are refused.
  if roots.toHashSet.len != roots.len:
    return err(what & ": a declaration is listed twice")
  ok(Opt.some(roots))

proc restrictedRoots(): seq[Root] =
  @[
    caMethodRoot("evaluate"),
    caEventRoot("grant_changed"),
    caEventRoot("policy_changed"),
  ]

proc compilePattern(s: LcnApScope, what: string): Result[Pattern, string] =
  case s.kind
  of LcnApScopeKind.lcn_Ap_provider_access:
    let p = s.arm_lcn_Ap_provider_access
    ?setOf(p.actions, true, what & ".actions")
    var r = Pattern(kind: pkProvider)
    var symbolic = true
    var info: ContractInfo
    case p.contract.kind
    of LcnApProviderAccessContractChoiceKind.Capability_authority:
      info = caContractInfo()
    of LcnApProviderAccessContractChoiceKind.Runtime_control:
      info = rcContractInfo()
    of LcnApProviderAccessContractChoiceKind.logos_Schema_commitment:
      symbolic = false
      info.commitment = p.contract.arm_logos_Schema_commitment
    r.contract = info.commitment
    for a in p.actions:
      r.paActions.incl PaActionKind(ord(a.kind))
    if p.providers.isSome:
      r.providers = Opt.some(?compileSubject(p.providers.get, what & ".providers"))
    if p.access.isSome:
      let a = p.access.get
      let
        methods = ?resolveDecls(
          a.methods, info.methods, symbolic, false, what & ".access.methods"
        )
        publish = ?resolveDecls(
          a.publish_events, info.events, symbolic, true, what & ".access.publish_events"
        )
        subscribe = ?resolveDecls(
          a.subscribe_events,
          info.events,
          symbolic,
          true,
          what & ".access.subscribe_events",
        )
        access = RouteAccess(
          methods: methods, publish_events: publish, subscribe_events: subscribe
        )
      if r.contract == caContract():
        if access.methods.isSome and caMethodRoot("evaluate") in access.methods.get:
          return err(what & ": evaluate is restricted to the protected engine path")
        if access.subscribe_events.isSome:
          for e in access.subscribe_events.get:
            if e == caEventRoot("grant_changed") or e == caEventRoot("policy_changed"):
              return err(what & ": grant_changed and policy_changed are restricted")
      r.access = Opt.some(access)
    ok(r)
  of LcnApScopeKind.lcn_Ap_runtime_control:
    let p = s.arm_lcn_Ap_runtime_control
    let info = rcContractInfo()
    var r = Pattern(kind: pkControl)
    r.methods = ?resolveDecls(p.methods, info.methods, true, false, what & ".methods")
    r.events = ?resolveDecls(p.events, info.events, true, true, what & ".events")
    for l in [r.methods, r.events]:
      if l.isSome:
        for x in l.get:
          if x in restrictedRoots():
            return err(what & ": a restricted declaration")
    if p.targets.isSome:
      r.targets = Opt.some(?compileSubject(p.targets.get, what & ".targets"))
    ok(r)
  of LcnApScopeKind.lcn_Ap_module_execution:
    let p = s.arm_lcn_Ap_module_execution
    ?setOf(p.actions, true, what & ".actions")
    ?setOf(p.modes, true, what & ".modes")
    ?setOf(p.placements, true, what & ".placements")
    var r = Pattern(kind: pkExecution)
    r.execTargets = ?compileSubject(p.targets, what & ".targets")
    for a in p.actions:
      r.meActions.incl MeActionKind(ord(a.kind))
    if p.modes.isSome:
      var m: set[ExecModeKind]
      for x in p.modes.get:
        m.incl ExecModeKind(ord(x.kind))
      r.modes = Opt.some(m)
    if p.placements.isSome:
      # placements need local-transport, and direct execution has none (l.324-325)
      if r.modes.isNone or r.modes.get != {ExecModeKind.Local_transport}:
        return err(what & ": placements need modes [\"local-transport\"]")
      var m: set[PlacementKind]
      for x in p.placements.get:
        m.incl PlacementKind(ord(x.kind))
      r.placements = Opt.some(m)
    ok(r)

proc compilePatterns(xs: seq[LcnApScope], what: string): Result[seq[Pattern], string] =
  ?setOf(xs, true, what & ".scopes")
  var r: seq[Pattern]
  for i, s in xs:
    r.add ?compilePattern(s, what & ".scopes[" & $i & "]")
  ok(r)

func commitmentOf(c: LcnApCommitment): CommitmentRequirements =
  CommitmentRequirements(request: c.request, response: c.response)

proc compileRule(x: LcnApRule, i: int): Result[Rule, string] =
  let what = "rules[" & $i & "]"
  let subjectOf =
    case x.kind
    of LcnApRuleKind.lcn_Ap_allow: x.arm_lcn_Ap_allow.subject
    of LcnApRuleKind.lcn_Ap_deny: x.arm_lcn_Ap_deny.subject
    of LcnApRuleKind.lcn_Ap_issue: x.arm_lcn_Ap_issue.subject
    of LcnApRuleKind.lcn_Ap_revoke: x.arm_lcn_Ap_revoke.subject
    of LcnApRuleKind.lcn_Ap_inspect: x.arm_lcn_Ap_inspect.subject
  let subject = ?compileSubject(subjectOf, what & ".subject")
  case x.kind
  of LcnApRuleKind.lcn_Ap_allow:
    let a = x.arm_lcn_Ap_allow
    var r = Rule(kind: rkAllow, subject: subject)
    r.allow = ?compilePatterns(a.scopes, what)
    if a.commitment.isSome:
      r.commitment = Opt.some(commitmentOf(a.commitment.get))
    ok(r)
  of LcnApRuleKind.lcn_Ap_deny:
    let a = x.arm_lcn_Ap_deny
    var r = Rule(kind: rkDeny, subject: subject)
    r.deny = ?compilePatterns(a.scopes, what)
    r.code = DenialKind.Scope_denied
    if a.code.isSome:
      r.code =
        case a.code.get.kind
        of LcnApDenyCodeChoiceKind.Consumer_denied: DenialKind.Consumer_denied
        of LcnApDenyCodeChoiceKind.Scope_denied: DenialKind.Scope_denied
        of LcnApDenyCodeChoiceKind.Target_denied: DenialKind.Target_denied
    ok(r)
  of LcnApRuleKind.lcn_Ap_issue:
    let a = x.arm_lcn_Ap_issue
    var r = Rule(kind: rkIssue, subject: subject)
    r.issueTargets = ?compileTarget(a.targets, false, what & ".targets")
    r.issue = ?compilePatterns(a.scopes, what)
    if a.max_validity_ms.isSome and a.max_validity_ms.get < MinValidityMs:
      return err(what & ".max_validity_ms is below 1000")
    r.maxValidityMs = a.max_validity_ms
    ok(r)
  of LcnApRuleKind.lcn_Ap_revoke:
    let a = x.arm_lcn_Ap_revoke
    var r = Rule(kind: rkRevoke, subject: subject)
    r.revokeTargets = ?compileTarget(a.targets, true, what & ".targets")
    ok(r)
  of LcnApRuleKind.lcn_Ap_inspect:
    let a = x.arm_lcn_Ap_inspect
    var r = Rule(kind: rkInspect, subject: subject)
    if a.grants.isSome:
      r.grants = Opt.some(?compileTarget(a.grants.get, true, what & ".grants"))
    if a.audit.isSome:
      r.audit = Opt.some(?compileTarget(a.audit.get, true, what & ".audit"))
    r.policyChanges = a.policy_changes.get(false)
    ok(r)

proc loadPolicy*(bytes: openArray[byte]): Result[Policy, string] =
  ## Decodes and validates a policy, resolving every name to its exact root.
  let p = decode(LcnAuthorityPolicy, bytes).valueOr:
    return err("policy: " & error)
  if not validSource(p.source):
    return err("policy: source does not match [a-z0-9][a-z0-9._-]{0,127}")
  var r = Policy(
    bytes: @bytes,
    digest: @(blake3(bytes)),
    source: p.source,
    validityMs: p.decision_validity_ms.get(DefaultValidityMs),
    auditRecords: DefaultAuditRecords,
  )
  if r.validityMs < MinValidityMs or r.validityMs > MaxValidityMs:
    return err("policy: decision_validity_ms is outside 1000..86400000")
  if p.audit.isSome and p.audit.get.records.isSome:
    r.auditRecords = p.audit.get.records.get
    if r.auditRecords < MinAuditRecords or r.auditRecords > MaxAuditRecords:
      return err("policy: audit.records is outside 1024..1048576")
  ?setOf(p.rules, true, "policy: rules")
  for i, x in p.rules:
    let rule = compileRule(x, i).valueOr:
      return err("policy: " & error)
    r.rules.add rule
  ok(r)

# Matching ---------------------------------------------------------------------------

func listCovers[T](pattern, requested: Opt[seq[T]]): bool =
  if pattern.isNone:
    true
  elif requested.isNone:
    false
  else:
    for x in requested.get:
      if x notin pattern.get:
        return false
    true

func providerEntryMatches(s: Subject, p: ProviderAddress, view: FactsView): bool =
  let b = view.backing(p.provider)
  b.kind == flFound and s.matches(snapshot(b.instance, b.facts))

proc patternContains*(p: Pattern, r: Scope, view: FactsView): bool =
  ## Whether the rule pattern `p` contains the requested scope `r` (§2.7).
  ## Every address in `r` is local and resolved before this runs.
  case p.kind
  of pkProvider:
    if r.kind != skProvider:
      return false
    let x = r.pa
    if x.contract != p.contract:
      return false
    for a in x.actions:
      if a.kind notin p.paActions:
        return false
    if p.providers.isSome:
      if x.providers.isNone:
        return false
      for e in x.providers.get:
        if not p.providers.get.providerEntryMatches(e, view):
          return false
    if p.access.isSome:
      if x.access.isNone:
        return false
      let pa = p.access.get
      let ra = x.access.get
      if not (
        listCovers(pa.methods, ra.methods) and
        listCovers(pa.publish_events, ra.publish_events) and
        listCovers(pa.subscribe_events, ra.subscribe_events)
      ):
        return false
    true
  of pkControl:
    if r.kind != skControl:
      return false
    let x = r.rc
    if not listCovers(p.methods, x.methods) or not listCovers(p.events, x.events):
      return false
    if p.targets.isSome:
      let t = p.targets.get
      if x.instances.isNone and x.modules.isNone and x.providers.isNone:
        return false
      if x.routes.isSome:
        return false
      if x.instances.isSome:
        for i in x.instances.get:
          let f = view.lookup(i)
          if f.kind != flFound or not t.matches(snapshot(i, f.facts)):
            return false
      if x.providers.isSome:
        for e in x.providers.get:
          if not t.providerEntryMatches(e, view):
            return false
      if x.modules.isSome:
        if not t.modulesOnly:
          return false
        for m in x.modules.get:
          if m notin t.modules.get:
            return false
    true
  of pkExecution:
    if r.kind != skExecution:
      return false
    let x = r.me
    for a in x.actions:
      if a.kind notin p.meActions:
        return false
    if p.modes.isSome:
      if x.modes.isNone:
        return false
      for m in x.modes.get:
        if m.kind notin p.modes.get:
          return false
    if p.placements.isSome:
      if x.placements.isNone:
        return false
      for m in x.placements.get:
        if m.kind notin p.placements.get:
          return false
    if x.instance.isSome:
      let f = view.lookup(x.instance.get)
      f.kind == flFound and f.facts.module == x.module and
        p.execTargets.matches(snapshot(x.instance.get, f.facts))
    else:
      p.execTargets.modulesOnly and x.module in p.execTargets.modules.get

proc containsAny*(ps: openArray[Pattern], r: Scope, view: FactsView): bool =
  for p in ps:
    if p.patternContains(r, view):
      return true
  false

func targetMatches*(
    t: Target,
    caller: Address,
    target: Address,
    targetFacts: FactsSnapshot,
    issuer: Opt[Address],
): bool =
  ## A rule's `targets`, `grants` or `audit` against one grant or record.
  ## `"self"`: the target is the caller; `"issued"`: the caller issued it.
  case t.kind
  of tkSelf:
    target == caller
  of tkIssued:
    issuer.isSome and issuer.get == caller
  of tkSubject:
    t.subject.matches(targetFacts)

# Visibility (CA §10 l.1382-1390) ----------------------------------------------------

func canRevoke*(
    p: Policy,
    caller: Address,
    callerFacts: FactsSnapshot,
    target: Address,
    targetFacts: FactsSnapshot,
    issuer: Opt[Address],
): bool =
  for r in p.rules:
    if r.kind == rkRevoke and r.subject.matches(callerFacts) and
        r.revokeTargets.targetMatches(caller, target, targetFacts, issuer):
      return true
  false

func canSeeGrant*(
    p: Policy,
    caller: Address,
    callerFacts: FactsSnapshot,
    target: Address,
    targetFacts: FactsSnapshot,
    issuer: Opt[Address],
): bool =
  ## An `inspect` rule's `grants`, or a `revoke` rule: being able to revoke a
  ## grant implies seeing it.
  for r in p.rules:
    if r.kind == rkInspect and r.grants.isSome and r.subject.matches(callerFacts) and
        r.grants.get.targetMatches(caller, target, targetFacts, issuer):
      return true
  p.canRevoke(caller, callerFacts, target, targetFacts, issuer)

func canSeeRecord*(
    p: Policy,
    caller: Address,
    callerFacts: FactsSnapshot,
    subject: Opt[FactsSnapshot],
    recordConsumer, recordTarget: Opt[Address],
    issuedByCaller: bool,
    policyChange: bool,
): bool =
  ## An `inspect` rule's `audit` against the record's subject snapshot;
  ## `"self"`: the record's consumer or target is the caller; `"issued"`: a
  ## record of a grant the caller issued. Policy-change records need
  ## `policy_changes: true`.
  for r in p.rules:
    if r.kind != rkInspect or not r.subject.matches(callerFacts):
      continue
    if policyChange:
      if r.policyChanges:
        return true
      continue
    if r.audit.isNone:
      continue
    let t = r.audit.get
    case t.kind
    of tkSelf:
      if (recordConsumer.isSome and recordConsumer.get == caller) or
          (recordTarget.isSome and recordTarget.get == caller):
        return true
    of tkIssued:
      if issuedByCaller:
        return true
    of tkSubject:
      if subject.isSome and t.subject.matches(subject.get):
        return true
  false

func inspectsPolicyChanges*(p: Policy, callerFacts: FactsSnapshot): bool =
  for r in p.rules:
    if r.kind == rkInspect and r.policyChanges and r.subject.matches(callerFacts):
      return true
  false

func hasIssuer*(p: Policy, callerFacts: FactsSnapshot): bool =
  ## [§0.1 U3] Whether any `issue` rule's subject matches the caller.
  for r in p.rules:
    if r.kind == rkIssue and r.subject.matches(callerFacts):
      return true
  false
