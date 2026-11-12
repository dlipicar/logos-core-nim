## Authority scopes: form, locality, containment and the pinned contracts
## (CA §3, §5; DECISIONS I84, G205, G207).
##
## Step 8b reuses all of this to build requests and check decisions.
##
## - **Form** (`checkScopeSet`, `checkShape`): every set-valued array is
##   strictly ascending by its elements' deterministic-CBOR bytes with no
##   duplicates (CA l.130-138), and every `actions`, `uses`, `scopes`,
##   `providers`, `routes`, `modules`, `instances`, `modes`, `placements`
##   array is non-empty (l.128-129). Method and event root lists may be empty:
##   an empty one permits none of that kind (l.126). Nothing is ever sorted
##   (CAP-0025). A failure is `invalid-request` (G205, TL-04 interim).
## - **Containment** (`covers`): required identity fields equal, constrained
##   lists of the narrower scope subsets of the broader one, absent optional
##   identities and lists unconstrained (l.119-127). An omitted provider
##   runtime id means the local Runtime, for comparison only (l.229-232).
## - **The contracts.** The Capability Authority and Runtime Control
##   commitments and declaration roots are computed from the mirrored spec
##   text (`caDocuments`, `rcDocuments`), never typed in (CAP-0089, CAP-0090).

{.push raises: [].}

import std/[algorithm, strutils, tables]
import results
import ../cbor
import ../commitment
import ../iface/[accept, names]
import ./logos_capability_authority_types
from ../runtime/rc_types import rcDocuments
import ../base/perthread

export results, logos_capability_authority_types

type
  Scope* = LogosNSCapabilityAuthorityScope
  ScopeKind* = LogosNSCapabilityAuthorityScopeKind
  ProviderAccessScope* = LogosNSCapabilityAuthorityProviderAccessScope
  RuntimeControlScope* = LogosNSCapabilityAuthorityRuntimeControlScope
  ModuleExecutionScope* = LogosNSCapabilityAuthorityModuleExecutionScope
  RemoteEnrollmentScope* = LogosNSCapabilityAuthorityRemoteEnrollmentScope
  PermissionScope* = LogosNSCapabilityAuthorityPermissionScope
  RouteAccess* = LogosNSCapabilityAuthorityRouteAccess
  PaAction* = LogosNSCapabilityAuthorityProviderAccessScopeActionsLIChoice
  PaActionKind* = LogosNSCapabilityAuthorityProviderAccessScopeActionsLIChoiceKind
  MeAction* = LogosNSCapabilityAuthorityModuleExecutionScopeActionsLIChoice
  MeActionKind* = LogosNSCapabilityAuthorityModuleExecutionScopeActionsLIChoiceKind
  ExecMode* = LogosNSCapabilityAuthorityExecutionMode
  ExecModeKind* = LogosNSCapabilityAuthorityExecutionModeKind
  Placement* = LogosNSCapabilityAuthorityHostedPlacement
  PlacementKind* = LogosNSCapabilityAuthorityHostedPlacementKind
  Address* = LogosNSRuntimeModuleInstanceAddress
  ProviderAddress* = LogosNSRuntimeModuleProviderAddress
  Grant* = LogosNSCapabilityAuthorityGrant
  GrantStatusKind* = LogosNSCapabilityAuthorityGrantStatusKind
  Decision* = LogosNSCapabilityAuthorityDecision
  Denial* = LogosNSCapabilityAuthorityDenial
  DenialKind* = LogosNSCapabilityAuthorityDenialCodeKind
  AuditRecord* = LogosNSCapabilityAuthorityAuditRecord
  AuditKind* = LogosNSCapabilityAuthorityAuditRecordKind
  CommitmentRequirements* = LogosNSCapabilityAuthorityCommitmentRequirements
  PolicyChangedEvent* = LogosNSCapabilityAuthorityPolicyChangedEvent
  CaCode* = LogosNSCapabilityAuthorityErrorCodeKind
  Root* = seq[byte] ## a 32-byte declaration root

  CaError* = object
    code*: CaCode
    detail*: string ## for diagnostics only; never sent (CAP-0154)

  ContractInfo* = object
    commitment*: SchemaCommitment
    methods*: Table[string, Root] ## by bare method name
    events*: Table[string, Root] ## by bare event name, without `_event`

const
  skProvider* = ScopeKind.logos_NS_capability_authority_Provider_access_scope
  skControl* = ScopeKind.logos_NS_capability_authority_Runtime_control_scope
  skExecution* = ScopeKind.logos_NS_capability_authority_Module_execution_scope
  skEnrollment* = ScopeKind.logos_NS_capability_authority_Remote_enrollment_scope
  skPermission* = ScopeKind.logos_NS_capability_authority_Permission_scope

template pa*(s: Scope): untyped =
  s.arm_logos_NS_capability_authority_Provider_access_scope

template rc*(s: Scope): untyped =
  s.arm_logos_NS_capability_authority_Runtime_control_scope

template me*(s: Scope): untyped =
  s.arm_logos_NS_capability_authority_Module_execution_scope

template enr*(s: Scope): untyped =
  s.arm_logos_NS_capability_authority_Remote_enrollment_scope

template pm*(s: Scope): untyped =
  s.arm_logos_NS_capability_authority_Permission_scope

func toScope*(x: ProviderAccessScope): Scope =
  Scope(kind: skProvider, arm_logos_NS_capability_authority_Provider_access_scope: x)

func toScope*(x: RuntimeControlScope): Scope =
  Scope(kind: skControl, arm_logos_NS_capability_authority_Runtime_control_scope: x)

func toScope*(x: ModuleExecutionScope): Scope =
  Scope(kind: skExecution, arm_logos_NS_capability_authority_Module_execution_scope: x)

func toScope*(x: RemoteEnrollmentScope): Scope =
  Scope(
    kind: skEnrollment, arm_logos_NS_capability_authority_Remote_enrollment_scope: x
  )

func toScope*(x: PermissionScope): Scope =
  Scope(kind: skPermission, arm_logos_NS_capability_authority_Permission_scope: x)

func caError*(code: CaCode, detail = ""): CaError =
  CaError(code: code, detail: detail)

func invalid(detail: string): CaError =
  caError(CaCode.Invalid_request, detail)

# Encodings and sets -----------------------------------------------------------------

proc enc*[T](x: T): seq[byte] =
  ## The deterministic-CBOR bytes of one set element.
  when T is string:
    encodeCbor(cbor(x))
  elif T is seq[byte]:
    encodeCbor(cbor(x))
  else:
    encodeCbor(toCbor(x))

proc isSet*[T](xs: openArray[T]): bool =
  ## [SPEC CA l.130-136] Strictly ascending by deterministic-CBOR bytes.
  var prev: seq[byte]
  for i in 0 ..< xs.len:
    let e = enc(xs[i])
    if i > 0 and cmpBytes(prev, e) >= 0:
      return false
    prev = e
  true

proc sortSet*[T](xs: var seq[T]) =
  ## For request builders only: a received value is never sorted (CAP-0025).
  var keyed: seq[(seq[byte], int)]
  for i, x in xs:
    keyed.add((enc(x), i))
  keyed.sort(
    proc(a, b: (seq[byte], int)): int =
      cmpBytes(a[0], b[0])
  )
  var sorted: seq[T]
  for (_, i) in keyed:
    sorted.add xs[i]
  xs = sorted

proc checkList[T](
    xs: Opt[seq[T]], nonEmpty: bool, what: string
): Result[void, CaError] =
  if xs.isSome:
    if nonEmpty and xs.get.len == 0:
      return err(invalid("empty " & what))
    if not isSet(xs.get):
      return err(invalid(what & " is not a set"))
  ok()

proc checkList[T](xs: seq[T], nonEmpty: bool, what: string): Result[void, CaError] =
  checkList(Opt.some(xs), nonEmpty, what)

# The pinned contracts ---------------------------------------------------------------

func eventName*(name: string): string =
  ## An event's name without the `_event` suffix of its declaration
  ## (INTERFACE §1.2): `grant_changed` for `grant_changed_event`.
  if name.endsWith("_event"):
    name[0 ..< name.len - "_event".len]
  else:
    name

proc loadContract(docs: (string, seq[string], seq[string])): ContractInfo =
  let set = acceptContractSet(docs[0], docs[1], docs[2], AcceptOptions(system: true))
  doAssert set.isOk, "a mirrored system contract does not accept: " & set.error
  let c = set.get.primary
  result.commitment = SchemaCommitment(schema_root: @(c.root))
  for m in c.model.methods:
    result.methods[bareMethodName(m.name, c.model.namespace)] =
      @(declarationRoot(c.model, m))
  for e in c.model.events:
    result.events[eventName(bareMethodName(e.name, c.model.namespace))] =
      @(declarationRoot(c.model, e))

perThread(caInfo, ContractInfo, loadContract(caDocuments()))
perThread(rcInfo, ContractInfo, loadContract(rcDocuments()))

proc caContractInfo*(): lent ContractInfo =
  caInfo()

proc rcContractInfo*(): lent ContractInfo =
  rcInfo()

proc caContract*(): SchemaCommitment =
  ## The Capability Authority contract (CA §11), from its mirrored text.
  caInfo().commitment

proc rcContract*(): SchemaCommitment =
  ## The Runtime Control contract (RUNTIME §9.3), from its mirrored text.
  rcInfo().commitment

proc caMethodRoot*(name: string): Root =
  doAssert name in caInfo().methods, "no Capability Authority method " & name
  caInfo().methods.getOrDefault(name)

proc caEventRoot*(name: string): Root =
  doAssert name in caInfo().events, "no Capability Authority event " & name
  caInfo().events.getOrDefault(name)

proc rcMethodRoot*(name: string): Root =
  doAssert name in rcInfo().methods, "no Runtime Control method " & name
  rcInfo().methods.getOrDefault(name)

proc rcEventRoot*(name: string): Root =
  doAssert name in rcInfo().events, "no Runtime Control event " & name
  rcInfo().events.getOrDefault(name)

# Restricted coverage (CAP-0248, CAP-0356; CA l.898, l.1375-1376) ------------------------

proc restrictedEvents(): seq[Root] =
  @[caEventRoot("grant_changed"), caEventRoot("policy_changed")]

proc containsAny(xs: Opt[seq[seq[byte]]], roots: openArray[Root]): bool =
  if xs.isSome:
    for x in xs.get:
      if x in roots:
        return true
  false

func hasAction*(s: ProviderAccessScope, a: PaActionKind): bool =
  for x in s.actions:
    if x.kind == a:
      return true
  false

proc isRestrictedOperation*(s: Scope): bool =
  ## A `subscribe-event` on the CA contract for `grant_changed` or
  ## `policy_changed`, or a `call` of `evaluate`: only the protected engine path
  ## carries those (§0.1 U7). Always denied `scope-denied`.
  if s.kind != skProvider or s.pa.contract != caContract() or s.pa.access.isNone:
    return false
  let access = s.pa.access.get
  (
    s.pa.hasAction(PaActionKind.Subscribe_event) and
    access.subscribe_events.containsAny(restrictedEvents())
  ) or (
    s.pa.hasAction(PaActionKind.Call) and
    access.methods.containsAny([caMethodRoot("evaluate")])
  )

proc namesRestricted*(s: Scope): bool =
  ## A provider-access scope on the CA contract that names `evaluate`,
  ## `grant_changed` or `policy_changed` explicitly: refused for issuance and in
  ## policy rules (§0.1 U7).
  if s.kind != skProvider or s.pa.contract != caContract() or s.pa.access.isNone:
    return false
  let access = s.pa.access.get
  access.subscribe_events.containsAny(restrictedEvents()) or
    access.methods.containsAny([caMethodRoot("evaluate")])

# Form -------------------------------------------------------------------------------

proc checkAccess(a: Opt[RouteAccess]): Result[void, CaError] =
  if a.isSome:
    ?checkList(a.get.methods, false, "access.methods")
    ?checkList(a.get.publish_events, false, "access.publish_events")
    ?checkList(a.get.subscribe_events, false, "access.subscribe_events")
  ok()

proc checkScope*(s: Scope): Result[void, CaError] =
  ## [SPEC CA l.128-138] The set-valued arrays of one scope.
  case s.kind
  of skProvider:
    ?checkList(s.pa.actions, true, "actions")
    ?checkList(s.pa.providers, true, "providers")
    ?checkList(s.pa.routes, true, "routes")
    ?checkAccess(s.pa.access)
  of skControl:
    ?checkList(s.rc.methods, false, "methods")
    ?checkList(s.rc.events, false, "events")
    ?checkList(s.rc.modules, true, "modules")
    ?checkList(s.rc.instances, true, "instances")
    ?checkList(s.rc.providers, true, "providers")
    ?checkList(s.rc.routes, true, "routes")
  of skExecution:
    ?checkList(s.me.actions, true, "actions")
    ?checkList(s.me.modes, true, "modes")
    ?checkList(s.me.placements, true, "placements")
  of skEnrollment:
    ?checkList(s.enr.actions, true, "actions")
    ?checkList(s.enr.uses, true, "uses")
  of skPermission:
    discard
  ok()

proc checkScopeSet*(scopes: openArray[Scope]): Result[void, CaError] =
  ## [SPEC CA l.128-138] A non-empty scope set, and every array in it.
  if scopes.len == 0:
    return err(invalid("empty scopes"))
  if not isSet(scopes):
    return err(invalid("scopes is not a set"))
  for s in scopes:
    ?checkScope(s)
  ok()

proc checkShape*(s: Scope): Result[void, CaError] =
  ## [SPEC CA l.303, l.323-327] Rules within one scope.
  case s.kind
  of skExecution:
    let m = s.me
    if m.version.isSome and m.package.isNone:
      return err(invalid("version without package"))
    if m.artifact.isSome and m.package.isNone:
      return err(invalid("artifact without package"))
    if m.placements.isSome:
      # placements require local-transport, and direct execution omits them
      # (l.324-325): every listed mode is local-transport.
      if m.modes.isNone:
        return err(invalid("placements without local-transport"))
      for x in m.modes.get:
        if x.kind != ExecModeKind.Local_transport:
          return err(invalid("placements with direct execution"))
  of skControl:
    if s.rc.contract != rcContract():
      return err(invalid("not the Runtime Control contract"))
  else:
    discard
  ok()

func isForeign(p: ProviderAddress, local: string): bool =
  p.runtime_instance_id.isSome and p.runtime_instance_id.get != local

proc checkLocality*(s: Scope, localRuntime: string): Result[void, CaError] =
  ## [SPEC CA l.229-232; G205] Remote enrollment and other Runtimes are not
  ## supported here: `unsupported-scope`.
  let unsupported = caError(CaCode.Unsupported_scope)
  case s.kind
  of skEnrollment:
    return err(unsupported)
  of skControl:
    if s.rc.runtime != localRuntime:
      return err(unsupported)
    if s.rc.providers.isSome:
      for p in s.rc.providers.get:
        if p.isForeign(localRuntime):
          return err(unsupported)
  of skExecution:
    if s.me.runtime != localRuntime:
      return err(unsupported)
  of skProvider:
    if s.pa.providers.isSome:
      for p in s.pa.providers.get:
        if p.isForeign(localRuntime):
          return err(unsupported)
  of skPermission:
    discard
  ok()

proc checkEvaluateShape*(
    scopes: openArray[Scope], maxScopes: int
): Result[void, CaError] =
  ## [IMPL] The rules for one evaluated operation (CA l.483-487; G207 interim,
  ## "TL-04, extended"): exactly one non-permission scope, one action per
  ## action-bearing scope, and for a call, publication or subscription one
  ## route and the one declaration being checked (l.288-289).
  if scopes.len > maxScopes:
    return err(invalid("too many scopes"))
  var operations = 0
  for s in scopes:
    if s.kind != skPermission:
      inc operations
  if operations != 1:
    return err(invalid("not exactly one operation"))
  for s in scopes:
    case s.kind
    of skProvider:
      let p = s.pa
      if p.actions.len != 1:
        return err(invalid("not exactly one action"))
      let a = p.actions[0].kind
      if a in
          {PaActionKind.Call, PaActionKind.Publish_event, PaActionKind.Subscribe_event}:
        if p.routes.isNone or p.routes.get.len != 1:
          return err(invalid("not exactly one route"))
        if p.access.isNone:
          return err(invalid("no access"))
        let acc = p.access.get
        let (one, others) =
          case a
          of PaActionKind.Call:
            (acc.methods, @[acc.publish_events, acc.subscribe_events])
          of PaActionKind.Publish_event:
            (acc.publish_events, @[acc.methods, acc.subscribe_events])
          else:
            (acc.subscribe_events, @[acc.methods, acc.publish_events])
        if one.isNone or one.get.len != 1:
          return err(invalid("not exactly one declaration"))
        for o in others:
          if o.isSome and o.get.len != 0:
            return err(invalid("a declaration of another kind"))
        if a == PaActionKind.Publish_event and
            (p.providers.isNone or p.providers.get.len != 1):
          return err(invalid("not exactly one publishing provider"))
    of skExecution:
      if s.me.actions.len != 1:
        return err(invalid("not exactly one action"))
    of skEnrollment:
      if s.enr.actions.len != 1:
        return err(invalid("not exactly one action"))
    else:
      discard
  ok()

proc validateScopes*(
    scopes: openArray[Scope], localRuntime: string, maxScopes: int, evaluating: bool
): Result[void, CaError] =
  ## The payload checks of `evaluate` and `issue_grant`, phase by phase across
  ## all scopes, the first failure in array order within a phase (G205):
  ## form (`invalid-request`), locality (`unsupported-scope`), then permission
  ## scopes (`unknown-permission`: no permission is defined here, §1.6).
  if scopes.len > maxScopes:
    return err(invalid("too many scopes"))
  ?checkScopeSet(scopes)
  for s in scopes:
    ?checkShape(s)
  if evaluating:
    ?checkEvaluateShape(scopes, maxScopes)
  for s in scopes:
    ?checkLocality(s, localRuntime)
  for s in scopes:
    if s.kind == skPermission:
      return err(caError(CaCode.Unknown_permission))
  ok()

proc canonicalOrder*(scopes: var seq[Scope]) =
  ## Puts every set-valued array of `scopes`, and `scopes` itself, in set
  ## order. For request builders: never applied to a received value.
  for s in scopes.mitems:
    case s.kind
    of skProvider:
      sortSet(s.pa.actions)
      if s.pa.providers.isSome:
        var x = s.pa.providers.get
        sortSet(x)
        s.pa.providers = Opt.some(x)
      if s.pa.routes.isSome:
        var x = s.pa.routes.get
        sortSet(x)
        s.pa.routes = Opt.some(x)
      if s.pa.access.isSome:
        var a = s.pa.access.get
        for l in [addr a.methods, addr a.publish_events, addr a.subscribe_events]:
          if l[].isSome:
            var x = l[].get
            sortSet(x)
            l[] = Opt.some(x)
        s.pa.access = Opt.some(a)
    of skControl:
      for l in [addr s.rc.methods, addr s.rc.events]:
        if l[].isSome:
          var x = l[].get
          sortSet(x)
          l[] = Opt.some(x)
      for l in [addr s.rc.modules, addr s.rc.instances, addr s.rc.routes]:
        if l[].isSome:
          var x = l[].get
          sortSet(x)
          l[] = Opt.some(x)
      if s.rc.providers.isSome:
        var x = s.rc.providers.get
        sortSet(x)
        s.rc.providers = Opt.some(x)
    of skExecution:
      sortSet(s.me.actions)
      if s.me.modes.isSome:
        var x = s.me.modes.get
        sortSet(x)
        s.me.modes = Opt.some(x)
      if s.me.placements.isSome:
        var x = s.me.placements.get
        sortSet(x)
        s.me.placements = Opt.some(x)
    of skEnrollment:
      sortSet(s.enr.actions)
      sortSet(s.enr.uses)
    of skPermission:
      discard
  sortSet(scopes)

# Containment (CA l.119-127) ---------------------------------------------------------

func local(p: ProviderAddress, localRuntime: string): (string, string) =
  (p.runtime_instance_id.get(localRuntime), p.provider)

func subsetOf[T](narrow, broad: openArray[T]): bool =
  for x in narrow:
    if x notin broad:
      return false
  true

func kindsSubset[T](narrow, broad: openArray[T]): bool =
  for x in narrow:
    var found = false
    for y in broad:
      if y.kind == x.kind:
        found = true
        break
    if not found:
      return false
  true

func listCovers[T](broad, narrow: Opt[seq[T]]): bool =
  ## An absent broader list is unconstrained; a present one needs a present
  ## narrower list that is a subset.
  if broad.isNone:
    true
  elif narrow.isNone:
    false
  else:
    subsetOf(narrow.get, broad.get)

func providersCover(
    broad, narrow: Opt[seq[ProviderAddress]], localRuntime: string
): bool =
  if broad.isNone:
    return true
  if narrow.isNone:
    return false
  var b: seq[(string, string)]
  for p in broad.get:
    b.add p.local(localRuntime)
  for p in narrow.get:
    if p.local(localRuntime) notin b:
      return false
  true

func identityCovers[T](broad, narrow: Opt[T]): bool =
  broad.isNone or (narrow.isSome and narrow.get == broad.get)

func accessCovers*(broad, narrow: Opt[RouteAccess]): bool =
  ## [SPEC CA l.124-125] A broader `access` needs a narrower one, with the
  ## Runtime's absent-list and empty-list semantics.
  if broad.isNone:
    return true
  if narrow.isNone:
    return false
  let b = broad.get
  let n = narrow.get
  listCovers(b.methods, n.methods) and listCovers(b.publish_events, n.publish_events) and
    listCovers(b.subscribe_events, n.subscribe_events)

func covers*(broader, narrower: Scope, localRuntime: string): bool =
  ## [SPEC CA l.119-127] Whether `narrower` is equal to or narrower than
  ## `broader`. A permission scope never covers here: no permission defines
  ## its containment (§1.6).
  if broader.kind != narrower.kind:
    return false
  case broader.kind
  of skProvider:
    let b = broader.pa
    let n = narrower.pa
    b.contract == n.contract and kindsSubset(n.actions, b.actions) and
      providersCover(b.providers, n.providers, localRuntime) and
      listCovers(b.routes, n.routes) and accessCovers(b.access, n.access)
  of skControl:
    let b = broader.rc
    let n = narrower.rc
    b.runtime == n.runtime and b.contract == n.contract and
      listCovers(b.methods, n.methods) and listCovers(b.events, n.events) and
      listCovers(b.modules, n.modules) and listCovers(b.instances, n.instances) and
      providersCover(b.providers, n.providers, localRuntime) and
      listCovers(b.routes, n.routes)
  of skExecution:
    let b = broader.me
    let n = narrower.me
    var modesOk = true
    if b.modes.isSome:
      modesOk = n.modes.isSome and kindsSubset(n.modes.get, b.modes.get)
    var placementsOk = true
    if b.placements.isSome:
      placementsOk =
        n.placements.isSome and kindsSubset(n.placements.get, b.placements.get)
    b.runtime == n.runtime and b.module == n.module and
      identityCovers(b.instance, n.instance) and kindsSubset(n.actions, b.actions) and
      modesOk and placementsOk and identityCovers(b.package, n.package) and
      identityCovers(b.version, n.version) and identityCovers(b.artifact, n.artifact)
  of skEnrollment:
    let b = broader.enr
    let n = narrower.enr
    b.remote_runtime == n.remote_runtime and kindsSubset(n.actions, b.actions) and
      kindsSubset(n.uses, b.uses)
  of skPermission:
    false

func coversAlternatives*(
    broader: openArray[Scope], narrower: Scope, localRuntime: string
): bool =
  ## [SPEC CA l.565-567] Runtime Control scopes that differ only in their
  ## subject selectors are alternatives: `narrower` must fit one of them whole.
  ## Selector fields from different alternatives are never combined.
  for b in broader:
    if covers(b, narrower, localRuntime):
      return true
  false
