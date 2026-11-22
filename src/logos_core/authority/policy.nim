## The Capability Authority's policy: load, validate, resolve, match [IMPL]
## (BCP l.359-360; CA §5, §6, §10; DECISIONS I84; docs/AUTHORITY-POLICY.md).
##
## The input is one deterministic-CBOR `lcn.authority_policy` value
## (`policy.cddl`). Loading checks what the schema cannot express and resolves
## every name to an exact root, so evaluation sees only exact roots and no
## alias survives load (CA l.451-452). A permission pattern is checked against
## the selected permission profile (DECISIONS I93): an undefined name or
## constraints that do not conform fail the load.
##
## Rules have no order. Deny overrides allow; the code of a denial is the first
## that applies in CA §7's table (l.783-794; G377).
##
## [G415; owner decision B5, item O1 (a), (x)] A forwarded consumer, the module
## instance an enrolled Runtime authenticated and forwards an operation for
## (RUNTIME l.1685-1699), is known by its instance id and its Runtime alone. A
## subject that names no Runtime matches local instances only; one whose
## `runtimes` names that Runtime matches it (`matches`). In an `inspect` rule's
## `grants` and `audit`, a subject that names no Runtime covers every
## consumer's records, local and forwarded (`covers`). Provider selectors and
## the targets of `runtime-control` and `module-execution` scopes name this
## Runtime's own instances and providers (`lcn.ap_selector`), never `runtimes`.

{.push raises: [].}

import std/[sets, strutils, tables]
import results
import logos_sdk/cbor
import logos_sdk/crypto/blake3
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
    ## Fields AND, entries OR; `{}` matches any local instance (G47; G415).
    runtimes*: Opt[seq[string]]
      ## [G415] the Runtimes whose forwarded consumers it names; none: local
      ## instances only (O1)
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
    pkPermission

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
    of pkPermission:
      permission*: string
      constraints*: Opt[seq[byte]] ## none: any conforming value

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
    runtime*: string
      ## [G415] a forwarded consumer's Runtime; empty: a local instance. A
      ## forwarded consumer has no module, signer or package here.
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

func forwarded*(instance, runtime: string): FactsSnapshot =
  ## [G415] A forwarded consumer's facts: its instance id and its Runtime.
  FactsSnapshot(instance: instance, runtime: runtime)

func factsMatch(s: Subject, f: FactsSnapshot): bool =
  if s.instances.isSome and f.instance notin s.instances.get:
    return false
  if s.modules.isSome and f.module notin s.modules.get:
    return false
  if s.signers.isSome and (f.signer.isNone or f.signer.get notin s.signers.get):
    return false
  if s.packages.isSome and (f.package.isNone or f.package.get notin s.packages.get):
    return false
  true

func matches*(s: Subject, f: FactsSnapshot): bool =
  ## [G47; G415, O1 (a)] A subject that names no Runtime matches local
  ## instances only; one that names Runtimes matches only forwarded consumers
  ## of those Runtimes.
  if s.runtimes.isSome:
    if f.runtime.len == 0 or f.runtime notin s.runtimes.get:
      return false
  elif f.runtime.len > 0:
    return false
  s.factsMatch(f)

func covers*(s: Subject, f: FactsSnapshot): bool =
  ## [G415, O1 (x)] An `inspect` rule's `grants` or `audit` subject against
  ## the facts of a record's consumer or a grant's target: one that names no
  ## Runtime covers every consumer, local and forwarded; one that names
  ## Runtimes covers only their forwarded consumers.
  if s.runtimes.isSome:
    if f.runtime.len == 0 or f.runtime notin s.runtimes.get:
      return false
  s.factsMatch(f)

func modulesOnly(s: Subject): bool =
  s.modules.isSome and s.instances.isNone and s.signers.isNone and s.packages.isNone

func named(s: Subject): bool =
  s.runtimes.isSome or s.instances.isSome or s.modules.isSome or s.signers.isSome or
    s.packages.isSome

func namesTarget(p: Pattern): bool =
  ## A pattern naming a provider, module or instance (CA l.784): a subject with
  ## at least one fact. `{}` and a permission name no target.
  case p.kind
  of pkProvider:
    p.providers.isSome and p.providers.get.named
  of pkControl:
    p.targets.isSome and p.targets.get.named
  of pkExecution:
    p.execTargets.named
  of pkPermission:
    false

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

func isRuntimeIdV4*(s: string): bool =
  ## [SPEC RUNTIME l.2592-2593] A lowercase canonical UUID version 4: what
  ## every Runtime id of the remote profiles is (8-4-4-4-12 lowercase hex
  ## digits, version 4, the RFC 9562 variant).
  if s.len != 36:
    return false
  for i, c in s:
    if i in [8, 13, 18, 23]:
      if c != '-':
        return false
    elif c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  s[14] == '4' and s[19] in {'8', '9', 'a', 'b'}

proc compileSelector(s: LcnApSelector, what: string): Result[Subject, string] =
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

proc compileSubject(s: LcnApSubject, what, runtimeId: string): Result[Subject, string] =
  ## [G415] `runtimes`: a set of lowercase UUIDv4 Runtime ids, never this
  ## Runtime's own (a subject names local instances by naming no Runtime),
  ## and never beside `modules`, `signers` or `packages`, which a forwarded
  ## consumer does not carry, so such a subject could match nothing (as CA
  ## l.305 for a field the subject does not carry). An id with no active
  ## enrollment loads and matches no consumer (`unenrolledRuntimes`).
  var r = ?compileSelector(
    LcnApSelector(
      instances: s.instances,
      modules: s.modules,
      signers: s.signers,
      packages: s.packages,
    ),
    what,
  )
  if s.runtimes.isSome:
    ?setOf(s.runtimes, true, what & ".runtimes")
    for id in s.runtimes.get:
      if not isRuntimeIdV4(id):
        return err(what & ".runtimes: not a lowercase UUIDv4 Runtime id: " & id)
      if runtimeId.len > 0 and id == runtimeId:
        return err(
          what & ".runtimes names this Runtime: a subject names local instances " &
            "by naming no Runtime"
        )
    if s.modules.isSome or s.signers.isSome or s.packages.isSome:
      return err(
        what & ": runtimes cannot stand beside modules, signers or packages, " &
          "which a consumer of another Runtime does not carry"
      )
    r.runtimes = s.runtimes
  ok(r)

proc compileTarget(
    t: LcnApTarget, issuedAllowed: bool, what, runtimeId: string
): Result[Target, string] =
  case t.kind
  of LcnApTargetKind.Self:
    ok(Target(kind: tkSelf))
  of LcnApTargetKind.Issued:
    if not issuedAllowed:
      return err(what & ": \"issued\" is valid only in revoke and inspect rules")
    ok(Target(kind: tkIssued))
  of LcnApTargetKind.lcn_Ap_subject:
    let subject = ?compileSubject(t.arm_lcn_Ap_subject, what, runtimeId)
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
  @[caEventRoot("grant_changed"), caEventRoot("policy_changed")]

proc compilePattern(
    s: LcnApScope, what: string, profile: PermissionProfile
): Result[Pattern, string] =
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
      r.providers = Opt.some(?compileSelector(p.providers.get, what & ".providers"))
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
      # [G378] `evaluate` may be named (CA l.1421): only a pattern naming it
      # contains a scope naming it for an allow or an issuance (`core.nim`).
      if r.contract == caContract():
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
      r.targets = Opt.some(?compileSelector(p.targets.get, what & ".targets"))
    ok(r)
  of LcnApScopeKind.lcn_Ap_module_execution:
    let p = s.arm_lcn_Ap_module_execution
    ?setOf(p.actions, true, what & ".actions")
    ?setOf(p.modes, true, what & ".modes")
    ?setOf(p.placements, true, what & ".placements")
    var r = Pattern(kind: pkExecution)
    r.execTargets = ?compileSelector(p.targets, what & ".targets")
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
  of LcnApScopeKind.lcn_Ap_permission:
    let p = s.arm_lcn_Ap_permission
    # [SPEC CA l.388-392; I93] Checked as a requested permission scope is.
    if not profile.defines(p.permission):
      return err(what & ": the permission " & p.permission & " is not defined")
    if p.constraints.isSome and profile.validate(p.permission, p.constraints.get).isErr:
      return err(what & ": constraints that do not conform to " & p.permission)
    ok(
      Pattern(kind: pkPermission, permission: p.permission, constraints: p.constraints)
    )

proc compilePatterns(
    xs: seq[LcnApScope], what: string, profile: PermissionProfile
): Result[seq[Pattern], string] =
  ?setOf(xs, true, what & ".scopes")
  var r: seq[Pattern]
  for i, s in xs:
    r.add ?compilePattern(s, what & ".scopes[" & $i & "]", profile)
  ok(r)

func commitmentOf(c: LcnApCommitment): CommitmentRequirements =
  CommitmentRequirements(request: c.request, response: c.response)

proc compileRule(
    x: LcnApRule, i: int, profile: PermissionProfile, runtimeId: string
): Result[Rule, string] =
  let what = "rules[" & $i & "]"
  let subjectOf =
    case x.kind
    of LcnApRuleKind.lcn_Ap_allow: x.arm_lcn_Ap_allow.subject
    of LcnApRuleKind.lcn_Ap_deny: x.arm_lcn_Ap_deny.subject
    of LcnApRuleKind.lcn_Ap_issue: x.arm_lcn_Ap_issue.subject
    of LcnApRuleKind.lcn_Ap_revoke: x.arm_lcn_Ap_revoke.subject
    of LcnApRuleKind.lcn_Ap_inspect: x.arm_lcn_Ap_inspect.subject
  let subject = ?compileSubject(subjectOf, what & ".subject", runtimeId)
  case x.kind
  of LcnApRuleKind.lcn_Ap_allow:
    let a = x.arm_lcn_Ap_allow
    var r = Rule(kind: rkAllow, subject: subject)
    r.allow = ?compilePatterns(a.scopes, what, profile)
    if a.commitment.isSome:
      r.commitment = Opt.some(commitmentOf(a.commitment.get))
    ok(r)
  of LcnApRuleKind.lcn_Ap_deny:
    let a = x.arm_lcn_Ap_deny
    var r = Rule(kind: rkDeny, subject: subject)
    r.deny = ?compilePatterns(a.scopes, what, profile)
    # [G377; CA l.783-784] A rule states one explicit denial: `consumer-denied`
    # unless it says `target-denied`, which only a rule whose every pattern
    # names a target may say.
    r.code = DenialKind.Consumer_denied
    if a.code.isSome:
      r.code =
        case a.code.get.kind
        of LcnApDenyCodeChoiceKind.Consumer_denied: DenialKind.Consumer_denied
        of LcnApDenyCodeChoiceKind.Target_denied: DenialKind.Target_denied
    if r.code == DenialKind.Target_denied:
      for i, p in r.deny:
        if not p.namesTarget:
          return err(
            what & ".scopes[" & $i & "]: a target-denied rule's pattern names no target"
          )
    ok(r)
  of LcnApRuleKind.lcn_Ap_issue:
    let a = x.arm_lcn_Ap_issue
    var r = Rule(kind: rkIssue, subject: subject)
    r.issueTargets = ?compileTarget(a.targets, false, what & ".targets", runtimeId)
    r.issue = ?compilePatterns(a.scopes, what, profile)
    if a.max_validity_ms.isSome and a.max_validity_ms.get < MinValidityMs:
      return err(what & ".max_validity_ms is below 1000")
    r.maxValidityMs = a.max_validity_ms
    ok(r)
  of LcnApRuleKind.lcn_Ap_revoke:
    let a = x.arm_lcn_Ap_revoke
    var r = Rule(kind: rkRevoke, subject: subject)
    r.revokeTargets = ?compileTarget(a.targets, true, what & ".targets", runtimeId)
    ok(r)
  of LcnApRuleKind.lcn_Ap_inspect:
    let a = x.arm_lcn_Ap_inspect
    var r = Rule(kind: rkInspect, subject: subject)
    if a.grants.isSome:
      r.grants =
        Opt.some(?compileTarget(a.grants.get, true, what & ".grants", runtimeId))
    if a.audit.isSome:
      r.audit = Opt.some(?compileTarget(a.audit.get, true, what & ".audit", runtimeId))
    r.policyChanges = a.policy_changes.get(false)
    ok(r)

proc loadPolicy*(
    bytes: openArray[byte], profile = NoProfile, runtimeId = ""
): Result[Policy, string] =
  ## Decodes and validates a policy, resolving every name to its exact root;
  ## permission patterns against `profile`; with `runtimeId`, a subject naming
  ## that Runtime is refused (G415).
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
    let rule = compileRule(x, i, profile, runtimeId).valueOr:
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

proc patternContains*(
    p: Pattern, r: Scope, view: FactsView, profile = NoProfile
): bool =
  ## Whether the rule pattern `p` contains the requested scope `r` (§2.7).
  ## Every address in `r` is local and resolved before this runs. A
  ## permission pattern contains a permission scope of the same name whose
  ## constraints conform and, when the pattern has constraints, are contained
  ## in them (CA l.129; I93).
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
  of pkPermission:
    if r.kind != skPermission or r.pm.permission != p.permission:
      return false
    if p.constraints.isNone:
      profile.validate(r.pm.permission, r.pm.constraints).isOk
    else:
      profile.contained(r.pm.permission, r.pm.constraints, p.constraints.get)

func patternCoversAction*(p: Pattern, r: Scope): bool =
  ## [SPEC CA l.792-793] Whether the pattern `p` covers the action of the
  ## requested scope `r`, as `scopes.coversAction` does for a grant's scope. A
  ## runtime-control pattern always means this Runtime and the Runtime Control
  ## contract, which a valid request names too (`checkShape`, `checkLocality`).
  case p.kind
  of pkProvider:
    if r.kind == skProvider:
      for a in r.pa.actions:
        if a.kind in p.paActions:
          return true
    false
  of pkControl:
    r.kind == skControl
  of pkExecution:
    if r.kind == skExecution:
      for a in r.me.actions:
        if a.kind in p.meActions:
          return true
    false
  of pkPermission:
    r.kind == skPermission and r.pm.permission == p.permission

func coversAnAction*(ps: openArray[Pattern], rs: openArray[Scope]): bool =
  ## Whether some pattern of `ps` covers the action of some scope of `rs`.
  for r in rs:
    for p in ps:
      if p.patternCoversAction(r):
        return true
  false

proc containsAny*(
    ps: openArray[Pattern], r: Scope, view: FactsView, profile = NoProfile
): bool =
  for p in ps:
    if p.patternContains(r, view, profile):
      return true
  false

proc containsEach*(
    ps: openArray[Pattern], rs: openArray[Scope], view: FactsView, profile = NoProfile
): bool =
  ## [G207 amended] Every scope of `rs` is contained in some pattern of `ps`:
  ## one rule covering a whole request.
  for r in rs:
    if not ps.containsAny(r, view, profile):
      return false
  true

func targetMatches*(
    t: Target,
    caller: Address,
    target: Address,
    targetFacts: FactsSnapshot,
    issuer: Opt[Address],
    inspecting = false,
): bool =
  ## A rule's `targets`, `grants` or `audit` against one grant or record.
  ## `"self"`: the target is the caller; `"issued"`: the caller issued it. An
  ## `inspect` rule's subject covers forwarded consumers when it names no
  ## Runtime (G415, O1 (x)); an `issue` or `revoke` rule's does not (O1 (a)).
  case t.kind
  of tkSelf:
    target == caller
  of tkIssued:
    issuer.isSome and issuer.get == caller
  of tkSubject:
    if inspecting:
      t.subject.covers(targetFacts)
    else:
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
        r.grants.get.targetMatches(
          caller, target, targetFacts, issuer, inspecting = true
        ):
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
      if subject.isSome and t.subject.covers(subject.get):
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

func issueCoversAction*(
    p: Policy, callerFacts: FactsSnapshot, scopes: openArray[Scope]
): bool =
  ## [G377, under UF-53] Whether an `issue` rule for the caller covers the
  ## action of a requested scope (CA l.788-789, l.792), whatever its targets.
  for r in p.rules:
    if r.kind == rkIssue and r.subject.matches(callerFacts) and
        r.issue.coversAnAction(scopes):
      return true
  false

# The load report (G415) ---------------------------------------------------------------

func runtimeRefs*(p: Policy): seq[tuple[what, id: string]] =
  ## [G415] Every Runtime a rule subject or an `issue`, `revoke` or `inspect`
  ## target names, with where.
  template check(where: string, s: Subject) =
    if s.runtimes.isSome:
      for id in s.runtimes.get:
        result.add((where, id))

  for i, r in p.rules:
    let what = "rules[" & $i & "]"
    check(what & ".subject", r.subject)
    case r.kind
    of rkIssue:
      if r.issueTargets.kind == tkSubject:
        check(what & ".targets", r.issueTargets.subject)
    of rkRevoke:
      if r.revokeTargets.kind == tkSubject:
        check(what & ".targets", r.revokeTargets.subject)
    of rkInspect:
      if r.grants.isSome and r.grants.get.kind == tkSubject:
        check(what & ".grants", r.grants.get.subject)
      if r.audit.isSome and r.audit.get.kind == tkSubject:
        check(what & ".audit", r.audit.get.subject)
    else:
      discard

func unenrolledReport*(
    refs: openArray[tuple[what, id: string]], enrolled: openArray[string]
): seq[string] =
  ## [G415] One line per Runtime named that is not actively enrolled: it
  ## loads and matches no consumer, so a revocation needs no policy edit, and
  ## the start names it.
  for r in refs:
    if r.id notin enrolled:
      result.add(
        r.what & " names Runtime " & r.id &
          ", which has no active logos.remote.tls-tcp enrollment: it matches no consumer"
      )

func unenrolledRuntimes*(p: Policy, enrolled: openArray[string]): seq[string] =
  ## [G415] `unenrolledReport` of the policy's own references.
  unenrolledReport(p.runtimeRefs, enrolled)
