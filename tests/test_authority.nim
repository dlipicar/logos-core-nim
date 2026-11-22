## The Capability Authority (step 8a; DECISIONS I84, G205-G207): scopes,
## policy, evaluate, ids, grants, lists, audit, notification, persistence and
## watches on the CA thread, and the provider module through a stand-in
## Runtime (`support/cafake.nim`). No engine and no dlopen: the engine suite
## is `test_authority_module`.

import std/[atomics, monotimes, os, sets, strutils, tables, times]
import unittest2
import logos_sdk/cbor
import
  ../src/logos_core/authority/
    [audit, core, cursor, ids, persist, policy, policy_types, state_types]
import logos_sdk/iface/accept
import logos_sdk/commitment
import logos_sdk/iface/names
from logos_sdk/kit/rc_types import rcDocuments
import ./support/[authfixture, cafake, permfixture], logos_sdk/testing/kitbuild

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "authority" / kitVariant
removeDir(work)
createDir(work)

var dirs = 0

proc freshDir(): string =
  inc dirs
  work / ("a" & $dirs)

# Response helpers ---------------------------------------------------------------------

proc decisionOf(r: EvaluateResponse): Decision =
  doAssert r.kind == LogosNSCapabilityAuthorityEvaluateResponseKind.Map_decision,
    "not a decision"
  r.arm_Map_decision.decision

proc errorOf(r: EvaluateResponse): CaCode =
  doAssert r.kind == LogosNSCapabilityAuthorityEvaluateResponseKind.Map_error,
    "not an error"
  r.arm_Map_error.error.code.kind

func allowed(d: Decision): bool =
  d.result.kind == LogosNSCapabilityAuthorityDecisionResultKind.Allow

func denialOf(d: Decision): DenialKind =
  d.denial.get.code.kind

proc grantOf(r: IssueGrantResponse): Grant =
  doAssert r.kind == LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_grant, $r.kind
  r.arm_Map_grant.grant

proc issueErrorOf(r: IssueGrantResponse): CaCode =
  doAssert r.kind == LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_error, $r.kind
  r.arm_Map_error.error.code.kind

proc issueDenialOf(r: IssueGrantResponse): DenialKind =
  doAssert r.kind == LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_denial,
    $r.kind
  r.arm_Map_denial.denial.code.kind

proc grantOf(r: RevokeGrantResponse): Grant =
  doAssert r.kind == LogosNSCapabilityAuthorityRevokeGrantResponseKind.Map_grant,
    $r.kind
  r.arm_Map_grant.grant

proc revokeErrorOf(r: RevokeGrantResponse): CaCode =
  doAssert r.kind == LogosNSCapabilityAuthorityRevokeGrantResponseKind.Map_error,
    $r.kind
  r.arm_Map_error.error.code.kind

proc grantOf(r: GetGrantResponse): Grant =
  doAssert r.kind == LogosNSCapabilityAuthorityGetGrantResponseKind.Map_grant, $r.kind
  r.arm_Map_grant.grant

proc getErrorOf(r: GetGrantResponse): CaCode =
  doAssert r.kind == LogosNSCapabilityAuthorityGetGrantResponseKind.Map_error, $r.kind
  r.arm_Map_error.error.code.kind

proc listOf(
    r: ListGrantsResponse
): LogosNSCapabilityAuthorityListGrantsResponseARMapGrantsMap =
  doAssert r.kind == LogosNSCapabilityAuthorityListGrantsResponseKind.Map_grants,
    $r.kind
  r.arm_Map_grants

proc listErrorOf(r: ListGrantsResponse): LogosNSCapabilityAuthorityError =
  doAssert r.kind == LogosNSCapabilityAuthorityListGrantsResponseKind.Map_error, $r.kind
  r.arm_Map_error.error

proc recordsOf(r: QueryAuditResponse): seq[AuditRecord] =
  doAssert r.kind == LogosNSCapabilityAuthorityQueryAuditResponseKind.Map_records,
    $r.kind
  r.arm_Map_records.records

proc queryErrorOf(r: QueryAuditResponse): CaCode =
  doAssert r.kind == LogosNSCapabilityAuthorityQueryAuditResponseKind.Map_error, $r.kind
  r.arm_Map_error.error.code.kind

proc same[T](a, b: T): bool =
  ## Equality by det-CBOR: the generated choice types have no `==`.
  when T is seq:
    if a.len != b.len:
      return false
    for i in 0 ..< a.len:
      if not same(a[i], b[i]):
        return false
    true
  else:
    encodeCbor(toCbor(a)) == encodeCbor(toCbor(b))

func statusKind(g: Grant): GrantStatusKind =
  g.status.kind

# Common policies -----------------------------------------------------------------------

const
  M1 = 10'u8 ## the method root alpha may call
  M2 = 11'u8 ## a method root nobody may call

proc alphaCalls(): LcnApRule =
  ## alpha may call M1 on the test contract through any provider.
  allowRule(
    subject(modules = @["alpha"]),
    @[
      paPattern(
        @[LcnApActionKind.Call],
        exact = testContract(),
        access = Opt.some(LcnApAccess(methods: decls(@[declRoot(root(M1))]))),
      )
    ],
  )

proc everythingFor(mods: seq[string]): seq[LcnApRule] =
  ## The grant rules a test needs: beta issues anything on the test contract
  ## to anyone, revokes and inspects what it issued; everyone inspects grants
  ## targeting itself and its own audit.
  @[
    issueRule(
      subject(modules = mods),
      targetSubject(anyone()),
      @[
        paPattern(
          @[
            LcnApActionKind.Call, LcnApActionKind.Discover,
            LcnApActionKind.Establish_route, LcnApActionKind.Subscribe_event,
          ],
          exact = testContract(),
        ),
        mePattern(anyone(), @[LcnApModuleExecutionActionsLIChoiceKind.Start]),
      ],
    ),
    revokeRule(subject(modules = mods), targetIssued()),
    inspectRule(
      anyone(), grants = Opt.some(targetSelf()), audit = Opt.some(targetSelf())
    ),
  ]

type Env = object
  dir: string
  facts: SharedFacts
  clock: Clock
  sink: ChannelSink
  profile: ProfileSource
  a: Authority

proc open(
    policy: seq[byte],
    limits = AuthorityLimits(),
    dir = "",
    facts: SharedFacts = nil,
    profile: ProfileSource = nil,
    enrolled: seq[string] = @[],
    runtimeId = Rt,
): Env =
  result.dir =
    if dir.len > 0:
      dir
    else:
      freshDir()
  result.facts =
    if facts == nil:
      fakeFacts()
    else:
      facts
  result.clock = newTestClock()
  result.sink = newChannelSink()
  result.profile = profile
  result.a = openTest(
    result.dir,
    policy,
    result.facts,
    result.clock,
    result.sink.sink,
    limits,
    runtimeId = runtimeId,
    profile = profile,
    enrolled = enrolled,
  )

proc close(e: var Env) =
  closeAuthority(e.a)
  freeChannelSink(e.sink)
  freeClock(e.clock)
  freeSharedFacts(e.facts)

proc reopen(e: var Env, policy: seq[byte], limits = AuthorityLimits()) =
  closeAuthority(e.a)
  e.a =
    openTest(e.dir, policy, e.facts, e.clock, e.sink.sink, limits, profile = e.profile)

proc now(e: Env): uint64 =
  uint64(e.clock.wallMs)

proc issue(
    e: Env, issuer, target: string, scopes: seq[Scope], expiresAt = Opt.none(uint64)
): IssueGrantResponse =
  e.a.issueGrant(
    moduleCaller(issuer),
    IssueGrantRequest(
      consumer: address(issuer),
      target: address(target),
      scopes: scopes,
      expires_at: expiresAt,
    ),
  )

proc revoke(
    e: Env, caller, gid: string, reason = Opt.none(string)
): RevokeGrantResponse =
  e.a.revokeGrant(
    moduleCaller(caller),
    RevokeGrantRequest(consumer: address(caller), grant_id: gid, reason: reason),
  )

proc get(e: Env, caller, gid: string): GetGrantResponse =
  e.a.getGrant(
    moduleCaller(caller), GetGrantRequest(consumer: address(caller), grant_id: gid)
  )

proc query(e: Env, caller: string, q = QueryAuditRequest()): seq[AuditRecord] =
  var r = q
  r.consumer = address(caller)
  recordsOf(e.a.queryAudit(moduleCaller(caller), r))

proc evaluate(e: Env, consumer: string, scopes: seq[Scope]): EvaluateResponse =
  e.a.evaluate(systemCaller(), evalRequest(consumer, scopes))

proc callM1(provider = "p-a"): Scope =
  callScope(root(M1), provider = provider)

proc auditAll(e: Env): seq[AuditRecord] =
  ## Every record, through a second authority-wide inspector.
  e.query("m-c")

proc rcModules(n: int): seq[Scope] =
  ## A runtime-control scope valid in every other respect: one method and a
  ## sorted `modules` list of `n` 64-character names, 66 encoded bytes each.
  var mods = newSeqOfCap[string](n)
  for i in 0 ..< n:
    mods.add "m" & align($i, 63, '0')
  @[
    toScope(
      RuntimeControlScope(
        runtime: Rt,
        contract: rcContract(),
        methods: Opt.some(@[rcContractInfo().methods.getOrDefault("stop_module")]),
        modules: Opt.some(mods),
      )
    )
  ]

proc scopesSize(s: seq[Scope]): int =
  ## The deterministic-CBOR length of a `scopes` array.
  var items: seq[CborValue]
  for x in s:
    items.add toCbor(x)
  encodeCbor(cborArray(items)).len

proc overMaxScopes(): seq[Scope] =
  ## The shortest such array over `MaxScopesBytes` (CA l.1199): past 23
  ## elements the list's head is 3 bytes, against 1 for one element.
  let n = (MaxScopesBytes - (scopesSize(rcModules(1)) - 67 + 3)) div 66
  rcModules(n + 1)

# cap.scopes ---------------------------------------------------------------------------

suite "cap.scopes: form, locality and containment":
  test "[CAP-0022] [CAP-0023] [CAP-0024] [CAP-0025] an empty or unordered set array or a duplicate is invalid-request, and nothing is sorted":
    var e = open(policyBytes(@[alphaCalls()]))
    let empty = pa(@[], routes = Opt.some(@["r-1"]))
    check e.evaluate("m-a", @[empty]).errorOf == CaCode.Invalid_request
    let b = callScope(root(M1), provider = "p-b")
    let a = callScope(root(M1), provider = "p-a")
    var unordered = @[a, b]
    if isSet(unordered):
      unordered = @[b, a]
    let before = enc(unordered[0]) & enc(unordered[1])
    check validateScopes(unordered, Rt, 64, evaluating = false).error.code ==
      CaCode.Invalid_request
    check enc(unordered[0]) & enc(unordered[1]) == before
    var actions = pa(@[PaActionKind.Subscribe_event, PaActionKind.Call])
    check checkScope(actions).error.code == CaCode.Invalid_request
    let dupRoutes = pa(@[PaActionKind.Call], routes = Opt.some(@["r-1", "r-1"]))
    check checkScope(dupRoutes).error.code == CaCode.Invalid_request
    var canon = @[actions]
    canonicalOrder(canon)
    check checkScopeSet(canon).isOk
    e.close()

  test "[CAP-0016] [CAP-0017] [CAP-0020] [CAP-0286] [CAP-0287] containment":
    let broad = pa(
      @[PaActionKind.Call, PaActionKind.Subscribe_event],
      routes = Opt.none(seq[string]),
      access = access(methods = Opt.some(@[root(1), root(2)])),
    )
    let narrow = pa(
      @[PaActionKind.Call],
      routes = Opt.some(@["r-1"]),
      access = access(methods = Opt.some(@[root(1)])),
    )
    check covers(broad, narrow, Rt)
    check not covers(narrow, broad, Rt)
    # equal identities: another contract is never covered
    check not covers(broad, pa(@[PaActionKind.Call], contract = testContract(2)), Rt)
    # a broader access needs a narrower one
    check not covers(broad, pa(@[PaActionKind.Call]), Rt)
    # an absent broader list is unconstrained; an empty one permits none
    let noMethods =
      pa(@[PaActionKind.Call], access = access(methods = Opt.some(newSeq[seq[byte]]())))
    let events =
      pa(@[PaActionKind.Call], access = access(subscribe = Opt.some(@[root(5)])))
    check covers(pa(@[PaActionKind.Call], access = access()), events, Rt)
    check not covers(noMethods, narrow, Rt)
    check covers(
      noMethods,
      pa(@[PaActionKind.Call], access = access(methods = Opt.some(newSeq[seq[byte]]()))),
      Rt,
    )
    # an absent optional identity is unconstrained, a present one must match
    check covers(meScope("alpha"), meScope("alpha", instance = Opt.some("m-a")), Rt)
    check not covers(meScope("alpha", instance = Opt.some("m-a")), meScope("alpha"), Rt)

  test "[CAP-0038] [CAP-0039] an omitted provider runtime id is the local one; a foreign one is unsupported and never matches":
    let local = pa(@[PaActionKind.Call], providers = Opt.some(@[providerAddr("p-a")]))
    let named = pa(
      @[PaActionKind.Call], providers = Opt.some(@[providerAddr("p-a", Opt.some(Rt))])
    )
    let foreign = pa(
      @[PaActionKind.Call],
      providers = Opt.some(@[providerAddr("p-a", Opt.some("rt-9"))]),
    )
    check covers(local, named, Rt)
    check covers(named, local, Rt)
    check not covers(local, foreign, Rt)
    check checkLocality(foreign, Rt).error.code == CaCode.Unsupported_scope

  test "[CAP-0054] [CAP-0056] [TXT-0385] Runtime Control: another contract is invalid-request, another runtime unsupported-scope; remote enrollment is unsupported-scope":
    let other = toScope(RuntimeControlScope(runtime: Rt, contract: testContract()))
    check validateScopes(@[other], Rt, 64, false).error.code == CaCode.Invalid_request
    let remote = toScope(RuntimeControlScope(runtime: "rt-9", contract: rcContract()))
    check validateScopes(@[remote], Rt, 64, false).error.code == CaCode.Unsupported_scope
    let fine = toScope(RuntimeControlScope(runtime: Rt, contract: rcContract()))
    check validateScopes(@[fine], Rt, 64, false).isOk
    # [SPEC CA l.801; G205] A scope kind this provider does not support.
    let enroll = toScope(
      RemoteEnrollmentScope(
        remote_runtime: "rt-9",
        actions: @[
          LogosNSCapabilityAuthorityRemoteEnrollmentScopeActionsLIChoice(
            kind:
              LogosNSCapabilityAuthorityRemoteEnrollmentScopeActionsLIChoiceKind.Enroll
          )
        ],
        uses: @[
          LogosNSCapabilityAuthorityRemoteEnrollmentScopeUsesLIChoice(
            kind:
              LogosNSCapabilityAuthorityRemoteEnrollmentScopeUsesLIChoiceKind.Runtime_control
          )
        ],
      )
    )
    check validateScopes(@[enroll], Rt, 64, true).error.code == CaCode.Unsupported_scope
    check validateScopes(@[enroll], Rt, 64, false).error.code == CaCode.Unsupported_scope
    var e = open(policyBytes(everythingFor(@["beta"])))
    check e.evaluate("m-b", @[enroll]).errorOf == CaCode.Unsupported_scope
    check e.issue("m-b", "m-a", @[enroll]).issueErrorOf == CaCode.Unsupported_scope
    e.close()

  test "[CAP-0058] [CAP-0059] [CAP-0060] [CAP-0061] module-execution shape rules":
    var s = ModuleExecutionScope(
      runtime: Rt, module: "alpha", actions: @[MeAction(kind: MeActionKind.Start)]
    )
    s.version = Opt.some("1")
    check checkShape(toScope(s)).error.code == CaCode.Invalid_request
    s.version = Opt.none(string)
    s.artifact = Opt.some("a")
    check checkShape(toScope(s)).error.code == CaCode.Invalid_request
    s.artifact = Opt.none(string)
    s.placements = Opt.some(@[Placement(kind: PlacementKind.Process)])
    check checkShape(toScope(s)).error.code == CaCode.Invalid_request
    s.modes = Opt.some(
      @[
        ExecMode(kind: ExecModeKind.Direct),
        ExecMode(kind: ExecModeKind.Local_transport),
      ]
    )
    check checkShape(toScope(s)).error.code == CaCode.Invalid_request
    s.modes = Opt.some(@[ExecMode(kind: ExecModeKind.Local_transport)])
    check checkShape(toScope(s)).isOk
    check validateScopes(@[meScope("alpha", runtimeId = "rt-9")], Rt, 64, false).error.code ==
      CaCode.Unsupported_scope

  test "[CAP-0096] [CAP-0097] [CAP-0288] one operation, one action, and a publisher backed by the consumer":
    var e = open(policyBytes(@[alphaCalls()]))
    let two = @[callM1(), callScope(root(M1), provider = "p-b")]
    var twoSorted = two
    sortSet(twoSorted)
    check e.evaluate("m-a", twoSorted).errorOf == CaCode.Invalid_request
    let twoActions = pa(
      @[PaActionKind.Call, PaActionKind.Discover],
      providers = Opt.some(@[providerAddr("p-a")]),
      routes = Opt.some(@["r-1"]),
      access = access(methods = Opt.some(@[root(M1)])),
    )
    check e.evaluate("m-a", @[twoActions]).errorOf == CaCode.Invalid_request
    let publish = pa(
      @[PaActionKind.Publish_event],
      providers = Opt.some(@[providerAddr("p-b")]),
      routes = Opt.some(@["r-1"]),
      access = access(publish = Opt.some(@[root(5)])),
    )
    check e.evaluate("m-a", @[publish]).errorOf == CaCode.Invalid_request
    e.close()

  test "[CAP-0435] [TXT-0398] a scopes array over 4,194,304 encoded bytes is invalid-request, for evaluate and issue_grant":
    let over = overMaxScopes()
    let under = rcModules(over[0].rc.modules.get.len - 1)
    check scopesSize(under) <= MaxScopesBytes and scopesSize(under) > MaxScopesBytes - 66
    check scopesSize(over) > MaxScopesBytes
    check validateScopes(under, Rt, 64, true).isOk
    check validateScopes(over, Rt, 64, true).error.code == CaCode.Invalid_request
    var e = open(
      policyBytes(
        @[
          allowRule(subject(modules = @["alpha"]), @[rcPattern()]),
          issueRule(
            subject(modules = @["beta"]), targetSubject(anyone()), @[rcPattern()]
          ),
        ]
      )
    )
    check e.evaluate("m-a", under).decisionOf.allowed
    check e.evaluate("m-a", over).errorOf == CaCode.Invalid_request
    check e.issue("m-b", "m-c", under).grantOf.scopes.len == 1
    check e.issue("m-b", "m-c", over).issueErrorOf == CaCode.Invalid_request
    e.close()

# cap.policy -----------------------------------------------------------------------------

suite "cap.policy: load, names and revisions":
  test "[IMPL] the documented example policy loads; non-canonical bytes and an unordered rule array are refused":
    let doc = readFile(repo / "docs" / "AUTHORITY-POLICY.md")
    let start = doc.find("```cbor-diag\n")
    check start >= 0
    let stop = doc.find("```", start + 12)
    let example = parseDiag(doc[start + 13 ..< stop]).expect("diagnostic notation")
    let bytes = encodeCbor(example)
    check loadPolicy(bytes).isOk
    var longer = @[0xB9'u8, 0x00, byte(example.entries.len)]
    longer.add bytes[1 .. ^1]
    check loadPolicy(longer).isErr
    var p = policyValue(@[alphaCalls(), inspectRule(anyone(), policyChanges = true)])
    if isSet(p.rules):
      p.rules = @[p.rules[1], p.rules[0]]
    check loadPolicy(encode(p).get).error.contains("not a set")

  test "[IMPL] the documented format is policy.cddl, verbatim":
    let doc = readFile(repo / "docs" / "AUTHORITY-POLICY.md")
    let start = doc.find("```cddl\n")
    check start >= 0
    let stop = doc.find("```", start + 8)
    let cddl = readFile(repo / "src" / "logos_core" / "authority" / "policy.cddl")
    check doc[start + 8 ..< stop] == cddl

  test "[CAP-0089] [CAP-0090] names resolve to the roots of the mirrored schemas; unknown or non-symbolic names are refused":
    let ca = acceptContractSet(
      caDocuments()[0], caDocuments()[1], caDocuments()[2], AcceptOptions(system: true)
    ).get
    check caContract().schema_root == @(ca.primary.root)
    let rc = acceptContractSet(
      rcDocuments()[0], rcDocuments()[1], rcDocuments()[2], AcceptOptions(system: true)
    ).get
    check rcContract().schema_root == @(rc.primary.root)
    var found = 0
    for m in ca.primary.model.methods:
      if bareMethodName(m.name, ca.primary.model.namespace) == "get_grant":
        inc found
        check caMethodRoot("get_grant") == @(declarationRoot(ca.primary.model, m))
    check found == 1
    let named = policyBytes(
      @[
        allowRule(
          anyone(),
          @[
            paPattern(
              @[LcnApActionKind.Call],
              contract = crCa,
              access = Opt.some(LcnApAccess(methods: decls(@[declName("get_grant")]))),
            )
          ],
        )
      ]
    )
    let p = loadPolicy(named).get
    check p.rules[0].allow[0].access.get.methods.get == @[caMethodRoot("get_grant")]
    let unknown = policyBytes(
      @[
        allowRule(
          anyone(),
          @[
            paPattern(
              @[LcnApActionKind.Call],
              contract = crCa,
              access =
                Opt.some(LcnApAccess(methods: decls(@[declName("no_such_method")]))),
            )
          ],
        )
      ]
    )
    check loadPolicy(unknown).isErr
    let exactNamed = policyBytes(
      @[
        allowRule(
          anyone(),
          @[
            paPattern(
              @[LcnApActionKind.Call],
              exact = testContract(),
              access = Opt.some(LcnApAccess(methods: decls(@[declName("get_grant")]))),
            )
          ],
        )
      ]
    )
    check loadPolicy(exactNamed).error.contains("symbolic")
    let rcNamed = policyBytes(
      @[allowRule(anyone(), @[rcPattern(methods = decls(@[declName("start_module")]))])]
    )
    check loadPolicy(rcNamed).get.rules[0].allow[0].methods.get ==
      @[rcMethodRoot("start_module")]

  test "[CAP-0248] [CAP-0356] [IMPL-DECISION G378] a rule naming grant_changed or policy_changed is refused at load; one naming evaluate loads":
    for (m, ev) in [
      (@[declName("evaluate")], newSeq[LcnApDecl]()),
      (newSeq[LcnApDecl](), @[declName("grant_changed")]),
      (newSeq[LcnApDecl](), @[declName("policy_changed_event")]),
    ]:
      var acc = LcnApAccess()
      if m.len > 0:
        acc.methods = decls(m)
      if ev.len > 0:
        acc.subscribe_events = decls(ev)
      let bytes = policyBytes(
        @[
          allowRule(
            anyone(),
            @[
              paPattern(
                @[LcnApActionKind.Call], contract = crCa, access = Opt.some(acc)
              )
            ],
          )
        ]
      )
      if m.len > 0:
        check loadPolicy(bytes).get.rules[0].allow[0].access.get.methods.get ==
          @[caMethodRoot("evaluate")]
      else:
        check loadPolicy(bytes).error.contains("restricted")
    let rcRestricted = policyBytes(
      @[
        allowRule(
          anyone(),
          @[rcPattern(events = decls(@[declRoot(caEventRoot("grant_changed"))]))],
        )
      ]
    )
    check loadPolicy(rcRestricted).error.contains("restricted")

  test "[CAP-0074] a permission pattern cannot be written, and the other bounds are checked":
    # lcn.ap_scope has no permission arm: such a rule does not decode.
    var v = toCbor(policyValue(@[alphaCalls()]))
    let perm =
      cborMap((cbor("kind"), cbor("permission")), (cbor("permission"), cbor("net")))
    for (k, x) in v.entries.mitems:
      if k.text == "rules":
        for (rk, rv) in x.items[0].entries.mitems:
          if rk.text == "scopes":
            rv.items[0] = perm
    check loadPolicy(encodeCbor(v)).isErr
    check loadPolicy(policyBytes(@[alphaCalls()], source = "Bad Source")).isErr
    check loadPolicy(policyBytes(@[alphaCalls()], validityMs = Opt.some(999'u64))).isErr
    check loadPolicy(policyBytes(@[alphaCalls()], records = Opt.some(100'u64))).isErr
    check loadPolicy(policyBytes(@[])).isErr
    let issuedIssue = policyBytes(
      @[
        issueRule(
          anyone(),
          targetIssued(),
          @[mePattern(anyone(), @[LcnApModuleExecutionActionsLIChoiceKind.Start])],
        )
      ]
    )
    check loadPolicy(issuedIssue).error.contains("issued")

  test "[CAP-0160] a restart with a changed digest is the next revision with one policy-change record at changed_at":
    let p1 = policyBytes(@[alphaCalls(), inspectRule(anyone(), policyChanges = true)])
    var e = open(p1)
    check e.a.policyRevision == 1
    e.reopen(p1)
    check e.a.policyRevision == 1
    check e.query("m-a").len == 0
    e.clock.advance(5_000)
    let p2 = policyBytes(@[inspectRule(anyone(), policyChanges = true)])
    e.reopen(p2)
    check e.a.policyRevision == 2
    let rs = e.query("m-a")
    check rs.len == 1
    check rs[0].kind == AuditKind.Policy_change_success
    check rs[0].arm_Policy_change_success.timestamp == e.now
    e.close()

# cap.evaluate --------------------------------------------------------------------------

suite "cap.evaluate: decisions":
  test "[CAP-0108] [CAP-0111] a rule allow repeats the requested scopes and is valid for the policy's validity":
    var e = open(policyBytes(@[alphaCalls()], validityMs = Opt.some(60_000'u64)))
    let d = e.evaluate("m-a", @[callM1()]).decisionOf
    check d.allowed
    check same(d.allowed_scopes.get, d.requested_scopes)
    check same(d.requested_scopes, @[callM1()])
    check d.issued_at < d.valid_until.get
    check d.valid_until.get == d.issued_at + 60_000
    check d.grant_ids.isNone
    check d.decision_id.startsWith("d-") and d.decision_id.len == IdLen
    check d.policy_revision == 1
    e.close()

  test "[CAP-0109] a deny carries only the denial, with the rule's code":
    var e = open(
      policyBytes(
        @[
          alphaCalls(),
          denyRule(
            subject(instances = @["m-a"]),
            @[paPattern(@[LcnApActionKind.Call], exact = testContract())],
            Opt.some(LcnApDenyCodeChoiceKind.Consumer_denied),
          ),
        ]
      )
    )
    let d = e.evaluate("m-a", @[callM1()]).decisionOf
    check not d.allowed
    check d.denialOf == DenialKind.Consumer_denied
    check d.allowed_scopes.isNone and d.valid_until.isNone and d.grant_ids.isNone and
      d.commitment.isNone
    e.close()

  test "[CAP-0110] [CAP-0302] [CAP-0017] a grant allow lists its grant and ends by its expiry; a grant that does not cover supports nothing":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let exp = e.now + 10_000
    let g = e.issue("m-b", "m-a", @[callM1()], Opt.some(exp)).grantOf
    let d = e.evaluate("m-a", @[callM1()]).decisionOf
    check d.allowed
    check d.grant_ids.get == @[g.grant_id]
    check d.valid_until.get == exp
    # the grant covers the call action, not the method (CA l.788, l.792)
    check e.evaluate("m-a", @[callScope(root(M2))]).decisionOf.denialOf ==
      DenialKind.Scope_denied
    check e.evaluate("m-b", @[callM1()]).decisionOf.denialOf == DenialKind.Not_granted
    e.close()

  test "[CAP-0430] [TXT-0375] [TXT-0376] [TXT-0379] [IMPL-DECISION G377] the deny codes: grant-revoked, grant-expired, else not-granted; a revoked holder comes before an expired one":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let g1 = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.revoke("m-b", g1.grant_id).grantOf
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Grant_revoked
    discard e.issue("m-b", "m-c", @[callM1()], Opt.some(e.now + 1_000)).grantOf
    e.clock.advance(1_000)
    check e.evaluate("m-c", @[callM1()]).decisionOf.denialOf == DenialKind.Grant_expired
    check e.evaluate("m-b", @[callM1()]).decisionOf.denialOf == DenialKind.Not_granted
    # A revoked and an expired grant that each contain the request: revoked
    # comes first in the table (CA l.785-786, l.794). Under G207 one grant
    # holds the whole request; "together with" waits on TL-04.
    discard e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now + 1_000)).grantOf
    e.clock.advance(1_000)
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Grant_revoked
    e.close()

  test "[CAP-0430] [TXT-0373] [TXT-0374] [TXT-0378] [TXT-0381] [TXT-0382] [IMPL-DECISION G377] the first applicable denial in table order":
    # 1. Explicit denials: consumer-denied before target-denied, whichever
    #    rule matches first, and before every lapsed grant (l.783-784, l.794).
    let toPa = paPattern(
      @[LcnApActionKind.Call],
      exact = testContract(),
      providers = Opt.some(subject(instances = @["m-a"])),
    )
    let anyCall = paPattern(@[LcnApActionKind.Call], exact = testContract())
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            denyRule(
              subject(modules = @["gamma"]),
              @[toPa],
              Opt.some(LcnApDenyCodeChoiceKind.Target_denied),
            ),
            denyRule(subject(modules = @["gamma"]), @[anyCall]),
            denyRule(
              subject(modules = @["alpha"]),
              @[toPa],
              Opt.some(LcnApDenyCodeChoiceKind.Target_denied),
            ),
          ]
      )
    )
    check e.evaluate("m-c", @[callM1()]).decisionOf.denialOf ==
      DenialKind.Consumer_denied
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.revoke("m-b", g.grant_id).grantOf
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Target_denied
    # through another provider the target-denied rule does not apply
    discard e.issue("m-b", "m-a", @[callM1(provider = "p-b")]).grantOf
    check e.evaluate("m-a", @[callM1(provider = "p-b")]).decisionOf.allowed
    e.close()
    # 2. A revoked grant comes before scope-denied, which an allow rule
    #    covering only the action gives (l.785, l.788).
    e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            allowRule(
              subject(modules = @["alpha"]),
              @[
                paPattern(
                  @[LcnApActionKind.Call],
                  exact = testContract(),
                  access = Opt.some(LcnApAccess(methods: decls(@[declRoot(root(M2))]))),
                )
              ],
            )
          ]
      )
    )
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Scope_denied
    let r = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.revoke("m-b", r.grant_id).grantOf
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Grant_revoked
    # 5. The action is covered whatever the contract, method or route
    #    (l.792): a call on another contract is scope-denied, not not-granted.
    check e.evaluate("m-a", @[callScope(root(M2), contract = testContract(2))]).decisionOf.denialOf ==
      DenialKind.Scope_denied
    # 6. Another action, or another consumer, is not-granted (l.789).
    check e.evaluate(
      "m-a",
      @[pa(@[PaActionKind.Discover], providers = Opt.some(@[providerAddr("p-a")]))],
    ).decisionOf.denialOf == DenialKind.Not_granted
    check e.evaluate("m-c", @[callM1()]).decisionOf.denialOf == DenialKind.Not_granted
    e.close()
    # A runtime-control scope's action is its Runtime and contract (l.793): a
    # rule for one method covers every other method's action.
    e = open(
      policyBytes(
        @[
          allowRule(
            subject(modules = @["alpha"]),
            @[rcPattern(methods = decls(@[declName("list_modules")]))],
          )
        ]
      )
    )
    let rcCall = proc(name: string): Scope =
      toScope(
        RuntimeControlScope(
          runtime: Rt,
          contract: rcContract(),
          methods: Opt.some(@[rcContractInfo().methods[name]]),
        )
      )
    check e.evaluate("m-a", @[rcCall("list_modules")]).decisionOf.allowed
    check e.evaluate("m-a", @[rcCall("get_self")]).decisionOf.denialOf ==
      DenialKind.Scope_denied
    check e.evaluate("m-b", @[rcCall("get_self")]).decisionOf.denialOf ==
      DenialKind.Not_granted
    e.close()
    # A permission scope's action is its name (l.793): constraints beyond the
    # rule's are scope-denied; a name no rule holds, beside a start no rule
    # holds, is not-granted.
    e = open(
      policyBytes(
        @[
          allowRule(
            subject(modules = @["beta"]), @[permPattern(Quota, Opt.some(quota(10)))]
          )
        ]
      ),
      profile = testProfile,
    )
    let start = meScope("alpha", instance = Opt.some("m-a"))
    var over = @[start, permissionScope(Quota, quota(11))]
    sortSet(over)
    check e.evaluate("m-b", over).decisionOf.denialOf == DenialKind.Scope_denied
    var ambient = @[start, permissionScope(HostAmbient, HostAmbientConstraints)]
    sortSet(ambient)
    check e.evaluate("m-b", ambient).decisionOf.denialOf == DenialKind.Not_granted
    e.close()
    # A target-denied rule must name its targets: `{}`, no providers, or a
    # permission names none, and the policy does not load (l.784).
    for bad in [
      anyCall,
      paPattern(
        @[LcnApActionKind.Call], exact = testContract(), providers = Opt.some(anyone())
      ),
      rcPattern(methods = decls(@[declName("stop_module")])),
      mePattern(anyone(), @[LcnApModuleExecutionActionsLIChoiceKind.Stop]),
    ]:
      check loadPolicy(
        policyBytes(
          @[denyRule(anyone(), @[bad], Opt.some(LcnApDenyCodeChoiceKind.Target_denied))]
        )
      ).error
        .contains("names no target")
    check loadPolicy(
      policyBytes(
        @[denyRule(anyone(), @[toPa], Opt.some(LcnApDenyCodeChoiceKind.Target_denied))]
      )
    ).isOk

  test "[CAP-0098] [CAP-0152] [CAP-0278] [CAP-0283] [CAP-0441] [TXT-0391] lost facts give authority-unavailable, never a deny, recorded with the scopes":
    var e = open(
      policyBytes(
        @[
          alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSubject(anyone())))
        ]
      )
    )
    let other = fakeFacts()
    e.facts.close()
    check e.evaluate("m-a", @[callM1()]).errorOf == CaCode.Authority_unavailable
    closeAuthority(e.a)
    e.a = openTest(
      e.dir,
      policyBytes(
        @[
          alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSubject(anyone())))
        ]
      ),
      other,
      e.clock,
      e.sink.sink,
    )
    let rs = e.query("m-a")
    check rs.len == 1
    check rs[0].kind == AuditKind.Evaluate_failure
    check same(rs[0].arm_Evaluate_failure.scopes.get, @[callM1()])
    check rs[0].arm_Evaluate_failure.error.kind == CaCode.Authority_unavailable
    freeSharedFacts(other)
    e.close()

  test "[CAP-0270] [CAP-0273] an unknown consumer is invalid-request; after retirement a grant for the old address supports nothing":
    var e = open(policyBytes(everythingFor(@["beta"])))
    check e.evaluate("m-zz", @[callM1()]).errorOf == CaCode.Invalid_request
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    check e.facts.removeInstance("m-a").isOk
    check e.evaluate("m-a", @[callM1(provider = "p-b")]).errorOf ==
      CaCode.Invalid_request
    e.close()

  test "[CAP-0274] [CAP-0275] [CAP-0276] [CAP-0277] [CAP-0091] subjects match the facts, never the scope's fields":
    let pattern = paPattern(@[LcnApActionKind.Call], exact = testContract())
    var e = open(
      policyBytes(
        @[
          allowRule(subject(signers = @[gammaSigner()]), @[pattern]),
          allowRule(
            subject(modules = @["beta"]),
            @[
              mePattern(
                subject(packages = @["pkg.gamma"]),
                @[LcnApModuleExecutionActionsLIChoiceKind.Start],
              )
            ],
          ),
        ]
      )
    )
    check e.evaluate("m-c", @[callM1()]).decisionOf.allowed
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Not_granted
    let ok =
      meScope("gamma", instance = Opt.some("m-c"), package = Opt.some("pkg.gamma"))
    check e.evaluate("m-b", @[ok]).decisionOf.allowed
    let lie =
      meScope("gamma", instance = Opt.some("m-c"), package = Opt.some("pkg.other"))
    check e.evaluate("m-b", @[lie]).errorOf == CaCode.Invalid_request
    let claimed =
      meScope("alpha", instance = Opt.some("m-a"), package = Opt.some("pkg.gamma"))
    check e.evaluate("m-b", @[claimed]).errorOf == CaCode.Invalid_request
    e.close()

  test "[CAP-0279] [CAP-0280] [CAP-0281] [CAP-0282] [CAP-0284] a facts change is seen by the next evaluation; validity is the policy's":
    var e = open(policyBytes(@[alphaCalls()]))
    let d = e.evaluate("m-a", @[callM1()]).decisionOf
    check d.valid_until.get == d.issued_at + DefaultValidityMs
    check e.facts.removeProvider("p-a").isOk
    check e.evaluate("m-a", @[callM1()]).errorOf == CaCode.Invalid_request
    e.close()

  test "[CAP-0093] [CAP-0094] the commitment is the union of request, rule and grant":
    let retain = LcnApCommitment(response: Opt.some("retain-root"))
    var e = open(
      policyBytes(
        @[
          allowRule(
            subject(modules = @["alpha"]),
            @[paPattern(@[LcnApActionKind.Call], exact = testContract())],
            Opt.some(retain),
          )
        ] & everythingFor(@["beta"])
      )
    )
    let req = Opt.some(CommitmentRequirements(request: Opt.some("retain-root")))
    let d =
      e.a.evaluate(systemCaller(), evalRequest("m-a", @[callM1()], req)).decisionOf
    check d.commitment.get.request == Opt.some("retain-root")
    check d.commitment.get.response == Opt.some("retain-root")
    discard e.a.issueGrant(
      moduleCaller("m-b"),
      IssueGrantRequest(
        consumer: address("m-b"),
        target: address("m-c"),
        scopes: @[callM1()],
        commitment: Opt.some(CommitmentRequirements(response: Opt.some("retain-root"))),
      ),
    ).grantOf
    let g =
      e.a.evaluate(systemCaller(), evalRequest("m-c", @[callM1()], req)).decisionOf
    check g.commitment.get.request == Opt.some("retain-root")
    check g.commitment.get.response == Opt.some("retain-root")
    check e.evaluate("m-a", @[callScope(root(M2))]).decisionOf.commitment.get.response ==
      Opt.some("retain-root")
    e.close()

  test "[CAP-0248] [CAP-0356] [IMPL-DECISION G378] grant_changed and policy_changed are denied under any rule; evaluate under a rule naming no methods; other CA scopes are not":
    var e = open(
      policyBytes(
        @[
          allowRule(
            anyone(),
            @[
              paPattern(
                @[
                  LcnApActionKind.Call, LcnApActionKind.Discover,
                  LcnApActionKind.Establish_route, LcnApActionKind.Subscribe_event,
                ],
                contract = crCa,
              )
            ],
          )
        ]
      )
    )
    let ca = caContract()
    let prov = Opt.some(@[providerAddr("p-a")])
    let route = Opt.some(@["r-1"])
    for ev in ["grant_changed", "policy_changed"]:
      let s = pa(
        @[PaActionKind.Subscribe_event],
        ca,
        prov,
        route,
        access(subscribe = Opt.some(@[caEventRoot(ev)])),
      )
      check e.evaluate("m-a", @[s]).decisionOf.denialOf == DenialKind.Scope_denied
    let call = pa(
      @[PaActionKind.Call],
      ca,
      prov,
      route,
      access(methods = Opt.some(@[caMethodRoot("evaluate")])),
    )
    check e.evaluate("m-a", @[call]).decisionOf.denialOf == DenialKind.Scope_denied
    let watch = pa(
      @[PaActionKind.Call],
      ca,
      prov,
      route,
      access(methods = Opt.some(@[caMethodRoot("watch_changes")])),
    )
    check e.evaluate("m-a", @[watch]).decisionOf.allowed
    check e.evaluate("m-a", @[pa(@[PaActionKind.Establish_route], ca, prov, route)]).decisionOf.allowed
    check e.evaluate("m-a", @[pa(@[PaActionKind.Discover], ca, prov)]).decisionOf.allowed
    e.close()

  test "[CAP-0248] [IMPL-DECISION G378] a call of evaluate is contained only by a rule, grant or issue rule naming it; a broad deny still matches it":
    let evalCall = callScope(caMethodRoot("evaluate"), caContract())
    let named = paPattern(
      @[LcnApActionKind.Call],
      contract = crCa,
      access = Opt.some(LcnApAccess(methods: decls(@[declName("evaluate")]))),
    )
    let broad = paPattern(@[LcnApActionKind.Call], contract = crCa)
    # A rule naming it allows it.
    var e = open(policyBytes(@[allowRule(anyone(), @[named])]))
    check e.evaluate("m-a", @[evalCall]).decisionOf.allowed
    e.close()
    # A broad deny beside it denies it.
    e =
      open(policyBytes(@[allowRule(anyone(), @[named]), denyRule(anyone(), @[broad])]))
    check e.evaluate("m-a", @[evalCall]).decisionOf.denialOf ==
      DenialKind.Consumer_denied
    e.close()
    # A grant with no method list covers its action, not the call.
    e = open(policyBytes(everythingFor(@["beta"])))
    let bare = pa(@[PaActionKind.Call], caContract())
    discard e.a.issueProtected(Source, address("m-a"), @[bare]).get
    check e.evaluate("m-a", @[evalCall]).decisionOf.denialOf == DenialKind.Scope_denied
    let g = e.a.issueProtected(Source, address("m-a"), @[evalCall]).get
    let d = e.evaluate("m-a", @[evalCall]).decisionOf
    check d.allowed and d.grant_ids.get == @[g.grant_id]
    e.close()
    # An issue rule with no method list does not issue a grant naming it; one
    # naming it does.
    e = open(
      policyBytes(
        @[
          issueRule(subject(modules = @["beta"]), targetSubject(anyone()), @[broad]),
          issueRule(subject(modules = @["gamma"]), targetSubject(anyone()), @[named]),
        ]
      )
    )
    check e.issue("m-b", "m-a", @[evalCall]).issueDenialOf == DenialKind.Scope_denied
    check e.issue("m-c", "m-a", @[evalCall]).grantOf.target == address("m-a")
    e.close()

  test "[CAP-0022] an empty method list is valid; empty actions are invalid-request":
    var e = open(
      policyBytes(
        @[
          allowRule(
            anyone(),
            @[paPattern(@[LcnApActionKind.Establish_route], exact = testContract())],
          )
        ]
      )
    )
    let eventsOnly = pa(
      @[PaActionKind.Establish_route],
      providers = Opt.some(@[providerAddr("p-a")]),
      routes = Opt.some(@["r-1"]),
      access = access(
        methods = Opt.some(newSeq[seq[byte]]()), subscribe = Opt.some(@[root(4)])
      ),
    )
    check e.evaluate("m-a", @[eventsOnly]).decisionOf.allowed
    check e.evaluate("m-a", @[pa(@[], routes = Opt.some(@["r-1"]))]).errorOf ==
      CaCode.Invalid_request
    e.close()

  test "[CAP-0072] [CAP-0073] [CAP-0074] [CAP-0202] [CAP-0423] [CAP-0427] without a permission profile a permission scope is unknown-permission, recorded without scopes":
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))]
      )
    )
    var scopes = @[meScope("alpha", instance = Opt.some("m-a")), permissionScope()]
    sortSet(scopes)
    check e.evaluate("m-a", scopes).errorOf == CaCode.Unknown_permission
    let rs = e.query("m-a")
    check rs.len == 1
    check rs[0].arm_Evaluate_failure.error.kind == CaCode.Unknown_permission
    check rs[0].arm_Evaluate_failure.scopes.isNone
    e.close()

  test "[CAP-0204] N evaluations give N records":
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))]
      )
    )
    for i in 0 ..< 7:
      discard e.evaluate(
        "m-a",
        @[
          if i mod 2 == 0:
            callM1()
          else:
            callScope(root(M2))
        ],
      )
    check e.query("m-a").len == 7
    e.close()

  test "[CAP-0092] nothing in a request adds a trust anchor":
    var e = open(
      policyBytes(
        @[
          allowRule(
            subject(signers = @[gammaSigner()]),
            @[paPattern(@[LcnApActionKind.Call], exact = testContract())],
          )
        ]
      )
    )
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Not_granted
    e.close()

# cap.permissions --------------------------------------------------------------------------

proc startA(action = MeActionKind.Start): Scope =
  meScope("alpha", instance = Opt.some("m-a"), action = action)

proc startReq(perms: varargs[Scope]): seq[Scope] =
  ## A start of `m-a` with `perms`, in set order.
  result = @[startA()]
  for p in perms:
    result.add p
  sortSet(result)

proc permQuota(limit: uint64): Scope =
  permissionScope(Quota, quota(limit))

proc permAmbient(): Scope =
  permissionScope(HostAmbient, HostAmbientConstraints)

proc startRule(perms: seq[LcnApScope]): LcnApRule =
  ## beta may start any instance, with `perms`, in one rule.
  allowRule(
    subject(modules = @["beta"]),
    @[mePattern(anyone(), @[LcnApModuleExecutionActionsLIChoiceKind.Start])] & perms,
  )

proc issuePerms(
    perms = @[permPattern(HostAmbient), permPattern(Quota)]
): seq[LcnApRule] =
  ## beta issues starts with `perms` to anyone and revokes what it issued.
  @[
    issueRule(
      subject(modules = @["beta"]),
      targetSubject(anyone()),
      @[mePattern(anyone(), @[LcnApModuleExecutionActionsLIChoiceKind.Start])] & perms,
    ),
    revokeRule(subject(modules = @["beta"]), targetIssued()),
  ]

suite "cap.permissions: the selected profile (I93)":
  test "[CAP-0072] [CAP-0073] [CAP-0074] a defined permission passes; an undefined one is unknown-permission; constraints that do not conform are invalid-constraints; unknown wins":
    let t = testProfile()
    check validateScopes(startReq(permQuota(5), permAmbient()), Rt, 64, true, t).isOk
    check validateScopes(startReq(permissionScope("lcn-test.other")), Rt, 64, true, t).error.code ==
      CaCode.Unknown_permission
    let nonShortest = @[0xa1'u8, 0x65, 0x6c, 0x69, 0x6d, 0x69, 0x74, 0x18, 0x05]
    for bad in [
      @[0xa0'u8], # no limit
      nonShortest, # not deterministic
      quota(5) & @[0x00'u8], # trailing bytes
      encodeCbor(cborMap((cbor("limit"), cbor("five")))), # not a uint64
    ]:
      check validateScopes(startReq(permissionScope(Quota, bad)), Rt, 64, true, t).error.code ==
        CaCode.Invalid_constraints
    check validateScopes(
      startReq(permissionScope(HostAmbient, encodeCbor(cborMap((cbor("a"), cbor(1)))))),
      Rt,
      64,
      true,
      t,
    ).error.code == CaCode.Invalid_constraints
    # every name is checked before any constraints, whatever the order
    check validateScopes(
      startReq(permissionScope(Quota, @[0xa0'u8]), permissionScope("zz-unknown")),
      Rt,
      64,
      true,
      t,
    ).error.code == CaCode.Unknown_permission
    check validateScopes(
      startReq(permissionScope(Quota, @[0xa0'u8]), permissionScope("aa-unknown")),
      Rt,
      64,
      true,
      t,
    ).error.code == CaCode.Unknown_permission
    var e =
      open(policyBytes(@[startRule(@[permPattern(Quota)])]), profile = testProfile)
    check e.evaluate("m-b", startReq(permissionScope(Quota, @[0xa0'u8]))).errorOf ==
      CaCode.Invalid_constraints
    check e.evaluate("m-b", startReq(permissionScope("lcn-test.other"))).errorOf ==
      CaCode.Unknown_permission
    check e.evaluate("m-b", startReq(permQuota(5))).decisionOf.allowed
    e.close()

  test "[CAP-0021] containment is the definition's: host-ambient by equality, a quota within a larger one; a grant of 10 covers a request of 5":
    let t = testProfile()
    check covers(permQuota(10), permQuota(5), Rt, t)
    check covers(permQuota(5), permQuota(5), Rt, t)
    check not covers(permQuota(5), permQuota(10), Rt, t)
    check covers(permAmbient(), permAmbient(), Rt, t)
    check not covers(permAmbient(), permQuota(5), Rt, t)
    check not covers(permQuota(10), permQuota(5), Rt, NoProfile)
    check not covers(permQuota(10), permQuota(5), Rt)
    var e = open(policyBytes(issuePerms()), profile = testProfile)
    let g = e.issue("m-b", "m-c", startReq(permQuota(10))).grantOf
    let d = e.evaluate("m-c", startReq(permQuota(5))).decisionOf
    check d.allowed and d.grant_ids.get == @[g.grant_id]
    check same(d.allowed_scopes.get, startReq(permQuota(5)))
    # the grant covers the start and the quota's name, not 11 (CA l.788, l.793)
    check e.evaluate("m-c", startReq(permQuota(11))).decisionOf.denialOf ==
      DenialKind.Scope_denied
    e.close()

  test "[IMPL-DECISION G207] permission scopes stand only beside a start: alone, beside a stop or beside a provider call they are invalid-request, with and without a profile":
    for prof in @[ProfileSource(nil), ProfileSource(testProfile)]:
      var e = open(policyBytes(@[alphaCalls()]), profile = prof)
      check e.evaluate("m-a", @[permAmbient()]).errorOf == CaCode.Invalid_request
      var stop = @[startA(MeActionKind.Stop), permAmbient()]
      sortSet(stop)
      check e.evaluate("m-a", stop).errorOf == CaCode.Invalid_request
      var call = @[callM1(), permAmbient()]
      sortSet(call)
      check e.evaluate("m-a", call).errorOf == CaCode.Invalid_request
      check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
      e.close()

  test "[IMPL-DECISION G207] one allow rule must hold the start and every permission; two rules that each hold a part deny scope-denied; a deny pattern on a permission denies":
    var e = open(
      policyBytes(@[startRule(@[permPattern(HostAmbient)])]), profile = testProfile
    )
    check e.evaluate("m-b", startReq(permAmbient())).decisionOf.allowed
    check e.evaluate("m-b", startReq()).decisionOf.allowed
    # the rule covers the start's action (CA l.788, G377)
    check e.evaluate("m-b", startReq(permAmbient(), permQuota(1))).decisionOf.denialOf ==
      DenialKind.Scope_denied
    e.close()
    e = open(
      policyBytes(
        @[
          startRule(@[]),
          allowRule(subject(modules = @["beta"]), @[permPattern(HostAmbient)]),
        ]
      ),
      profile = testProfile,
    )
    check e.evaluate("m-b", startReq()).decisionOf.allowed
    check e.evaluate("m-b", startReq(permAmbient())).decisionOf.denialOf ==
      DenialKind.Scope_denied
    e.close()
    e = open(
      policyBytes(@[startRule(@[permPattern(Quota, Opt.some(quota(10)))])]),
      profile = testProfile,
    )
    check e.evaluate("m-b", startReq(permQuota(10))).decisionOf.allowed
    check e.evaluate("m-b", startReq(permQuota(11))).decisionOf.denialOf ==
      DenialKind.Scope_denied
    e.close()
    e = open(
      policyBytes(
        @[
          startRule(@[permPattern(Quota)]),
          denyRule(
            subject(modules = @["beta"]), @[permPattern(Quota, Opt.some(quota(100)))]
          ),
        ]
      ),
      profile = testProfile,
    )
    # a deny rule without a code is consumer-denied (G377)
    check e.evaluate("m-b", startReq(permQuota(5))).decisionOf.denialOf ==
      DenialKind.Consumer_denied
    check e.evaluate("m-b", startReq(permQuota(500))).decisionOf.allowed
    check e.evaluate("m-b", startReq()).decisionOf.allowed
    e.close()

  test "[CAP-0063] [IMPL-DECISION G207] one grant covering the start and its permissions allows and is listed; two grants that cover it only together deny":
    var e = open(policyBytes(issuePerms()), profile = testProfile)
    let exp = e.now + 10_000
    let g = e.issue("m-b", "m-c", startReq(permAmbient()), Opt.some(exp)).grantOf
    let d = e.evaluate("m-c", startReq(permAmbient())).decisionOf
    check d.allowed
    check d.grant_ids.get == @[g.grant_id]
    check d.valid_until.get <= exp
    check same(d.allowed_scopes.get, startReq(permAmbient()))
    # g holds the start but not the quota, and a grant of the quota alone
    # holds no start: neither contains the request, and both cover an action
    discard e.issue("m-b", "m-c", @[permQuota(10)]).grantOf
    check e.evaluate("m-c", startReq(permQuota(5))).decisionOf.denialOf ==
      DenialKind.Scope_denied
    let both = e.issue("m-b", "m-c", startReq(permQuota(10))).grantOf
    check e.evaluate("m-c", startReq(permQuota(5))).decisionOf.grant_ids.get ==
      @[both.grant_id]
    e.close()

  test "[CAP-0074] a policy naming an undefined permission or constraints that do not conform does not load; issue_grant validates permission scopes alike":
    let t = testProfile()
    check loadPolicy(policyBytes(@[startRule(@[permPattern(Quota)])]), t).isOk
    check loadPolicy(policyBytes(@[startRule(@[permPattern(Quota)])])).isErr
    check loadPolicy(policyBytes(@[startRule(@[permPattern("lcn-test.other")])]), t).error
      .contains("not defined")
    check loadPolicy(
      policyBytes(@[startRule(@[permPattern(Quota, Opt.some(@[0xa0'u8]))])]), t
    ).error
      .contains("conform")
    var e = open(policyBytes(issuePerms()), profile = testProfile)
    check e.issue("m-b", "m-c", startReq(permissionScope("lcn-test.other"))).issueErrorOf ==
      CaCode.Unknown_permission
    check e.issue("m-b", "m-c", startReq(permissionScope(Quota, @[0xa0'u8]))).issueErrorOf ==
      CaCode.Invalid_constraints
    check e.issue("m-b", "m-c", startReq(permissionScope(Unenforced, @[0xa0'u8]))).issueDenialOf ==
      DenialKind.Scope_denied
    discard e.issue("m-b", "m-c", startReq(permQuota(5))).grantOf
    check e.a.replacePolicy(policyBytes(issuePerms(@[permPattern(Unenforced)]))).isOk
    check e.a.replacePolicy(policyBytes(@[startRule(@[permPattern("lcn-test.other")])])).isErr
    e.close()

  test "[IMPL] an active grant naming a permission the selected profile does not define fails the open closed; a revoked one does not":
    var e = open(policyBytes(issuePerms()), profile = testProfile)
    let g = e.issue("m-b", "m-c", startReq(permQuota(5))).grantOf
    closeAuthority(e.a)
    let v1 = policyBytes(issuePerms(@[permPattern(HostAmbient)]))
    let refused = openAuthority(
      testConfig(e.dir, v1, e.facts, e.clock, e.sink.sink, profile = profileV1)
    )
    check refused.isErr and refused.error.contains("lcn-test.quota")
    e.a = openTest(
      e.dir,
      policyBytes(issuePerms()),
      e.facts,
      e.clock,
      e.sink.sink,
      profile = testProfile,
    )
    discard e.revoke("m-b", g.grant_id).grantOf
    closeAuthority(e.a)
    e.a = openTest(e.dir, v1, e.facts, e.clock, e.sink.sink, profile = profileV1)
    check e.evaluate("m-c", startReq(permQuota(5))).errorOf == CaCode.Unknown_permission
    e.close()

# cap.ids ---------------------------------------------------------------------------------

proc noEntropy(dest: var openArray[byte]): bool =
  false

suite "cap.ids: decision and grant ids":
  test "[CAP-0298] [CAP-0299] [CAP-0300] unique ids, a fresh prefix at every open, disjoint for copied state":
    var a = newIdAllocator().get
    var seen = initHashSet[string]()
    for i in 0 ..< 100_000:
      seen.incl a.nextId('d').get
    check seen.len == 100_000
    var e = open(policyBytes(@[alphaCalls()]))
    let d1 = e.evaluate("m-a", @[callM1()]).decisionOf.decision_id
    e.reopen(policyBytes(@[alphaCalls()]))
    let d2 = e.evaluate("m-a", @[callM1()]).decisionOf.decision_id
    check d1[2 .. 33] != d2[2 .. 33]
    closeAuthority(e.a)
    let copy = freshDir()
    copyDir(e.dir, copy)
    removeFile(copy / "lock")
    for d in [copy, copy / GrantsDir, copy / AuditDir]:
      setFilePermissions(d, {fpUserRead, fpUserWrite, fpUserExec})
    var f = open(policyBytes(@[alphaCalls()]), dir = copy)
    e.a = openTest(e.dir, policyBytes(@[alphaCalls()]), e.facts, e.clock, e.sink.sink)
    let d3 = e.evaluate("m-a", @[callM1()]).decisionOf.decision_id
    let d4 = f.evaluate("m-a", @[callM1()]).decisionOf.decision_id
    check d3[2 .. 33] != d4[2 .. 33]
    f.close()
    e.close()

  test "[CAP-0301] no entropy fails the open; an exhausted allocator fails the evaluation without a decision":
    let facts = fakeFacts()
    var clock = newTestClock()
    var cfg = testConfig(
      freshDir(), policyBytes(@[alphaCalls()]), facts, clock, AuthoritySink()
    )
    cfg.entropy = noEntropy
    check openAuthority(cfg).error.contains("entropy")
    freeSharedFacts(facts)
    freeClock(clock)
    var a = newIdAllocator().get
    a.exhaustForTest()
    check a.nextId('d').isSome
    check a.nextId('d').isNone

# cap.grants --------------------------------------------------------------------------

suite "cap.grants: issue, revoke, expiry, issuers":
  test "[CAP-0137] [CAP-0138] [CAP-0139] an issued grant is active; a past expires_at is invalid-request":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    check g.statusKind == GrantStatusKind.Active
    check g.grant_id.startsWith("g-") and g.grant_id.len == IdLen
    check e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now)).issueErrorOf ==
      CaCode.Invalid_request
    e.close()

  test "[CAP-0140] [CAP-0144] expiry is read before the timer runs; the timer records it at expires_at and emits once":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let exp = e.now + 2_000
    let g = e.issue("m-b", "m-a", @[callM1()], Opt.some(exp)).grantOf
    check e.sink.drain().len == 1
    e.clock.advance(2_000)
    check e.get("m-a", g.grant_id).grantOf.statusKind == GrantStatusKind.Expired
    e.a.tick()
    let evs = e.sink.drain()
    check evs.len == 1
    check evs[0].grant.status.kind == GrantStatusKind.Expired
    let rs = e.query("m-a", QueryAuditRequest(grant_id: Opt.some(g.grant_id)))
    check rs.len == 2
    check rs[0].kind == AuditKind.Grant_expired_success
    check rs[0].arm_Grant_expired_success.timestamp == exp
    e.a.tick()
    check e.sink.drain().len == 0
    e.close()

  test "[CAP-0141] [CAP-0142] [CAP-0143] [TXT-0389] revocation keeps the time and reason; an expired grant is not active; a repeat is idempotent":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    e.clock.advance(10)
    let r = e.revoke("m-b", g.grant_id, Opt.some("done")).grantOf
    check r.statusKind == GrantStatusKind.Revoked
    check r.revoked_at.get == e.now
    check r.revocation_reason.get == "done"
    e.clock.advance(10)
    let again = e.revoke("m-b", g.grant_id).grantOf
    check same(again, r)
    let x = e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now + 5)).grantOf
    e.clock.advance(5)
    check e.revoke("m-b", x.grant_id).revokeErrorOf == CaCode.Grant_not_active
    e.close()

  test "[CAP-0323] [IMPL-DECISION G377] issuance policy: not-granted, scope-denied, and max_validity_ms":
    var e = open(
      policyBytes(
        @[
          issueRule(
            subject(modules = @["beta"]),
            targetSubject(subject(modules = @["alpha"])),
            @[paPattern(@[LcnApActionKind.Call], exact = testContract())],
            Opt.some(5_000'u64),
          )
        ]
      )
    )
    # no issue rule for the caller; another target, under a rule covering the
    # action; an action no issue rule of the caller covers
    check e.issue("m-a", "m-a", @[callM1()]).issueDenialOf == DenialKind.Not_granted
    check e.issue("m-b", "m-c", @[callM1()], Opt.some(e.now + 1_000)).issueDenialOf ==
      DenialKind.Scope_denied
    check e.issue("m-b", "m-a", @[meScope("alpha")], Opt.some(e.now + 1_000)).issueDenialOf ==
      DenialKind.Not_granted
    check e.issue("m-b", "m-a", @[callM1()]).issueDenialOf == DenialKind.Scope_denied
    check e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now + 5_001)).issueDenialOf ==
      DenialKind.Scope_denied
    discard e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now + 5_000)).grantOf
    e.close()

  test "[CAP-0262] [CAP-0263] no existence oracle: a caller with no issue rule is not-granted whatever it names":
    var e = open(policyBytes(everythingFor(@["beta"])))
    check e.issue("m-a", "m-zz", @[callM1()]).issueDenialOf == DenialKind.Not_granted
    check e.issue("m-a", "m-b", @[callM1(provider = "p-zz")]).issueDenialOf ==
      DenialKind.Not_granted
    let pkg =
      meScope("gamma", instance = Opt.some("m-c"), package = Opt.some("pkg.other"))
    check e.issue("m-a", "m-b", @[pkg]).issueDenialOf == DenialKind.Not_granted
    check e.issue("m-b", "m-zz", @[callM1()]).issueErrorOf == CaCode.Invalid_request
    e.close()

  test "[TXT-0359] [IMPL-DECISION G81] the half with no Runtime enrolled: a grant target on another Runtime does not resolve, so issuance is invalid-request":
    # Remote enrollment is not built (5-7a), so no other Runtime is enrolled:
    # a target naming one never resolves, whether or not its instance id is
    # known here. 5-7a adds the enrolled half under the same tag.
    var e = open(policyBytes(everythingFor(@["beta"])))
    for instance in ["m-a", "m-zz"]:
      check e.a.issueGrant(
        moduleCaller("m-b"),
        IssueGrantRequest(
          consumer: address("m-b"),
          target: address(instance, "rt-9"),
          scopes: @[callM1()],
        ),
      ).issueErrorOf == CaCode.Invalid_request
    check e.query("m-b").len == 2
    e.close()

  test "[IMPL] D7: an expiry passed during the write fails invalid-request and leaves nothing; D8: a failed expiry write still emits":
    var e = open(policyBytes(everythingFor(@["beta"])))
    # D7 by a clock moved between the first check and the re-check: a deadline
    # of now + 0 is refused at the form step, so the re-check is shown with a
    # grant whose deadline is reached while its document is written, by moving
    # the clock from the sink of a concurrent grant.
    let base = e.now
    let g = e.issue("m-b", "m-a", @[callM1()], Opt.some(base + 3_000)).grantOf
    discard e.sink.drain()
    e.a.injectWriteFailures(all = true)
    e.clock.advance(3_000)
    e.a.tick()
    check e.sink.drain().len == 1 # emitted although its record could not be written
    e.a.injectWriteFailures()
    e.a.tick()
    check (e.dir / GrantsDir / (g.grant_id & ".cbor")).fileExists
    check e.query("m-a", QueryAuditRequest(grant_id: Opt.some(g.grant_id))).len == 2
    e.close()

  test "[IMPL] internal-error: an audit record that cannot be made fails issue_grant and revoke_grant, and changes nothing":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.sink.drain()
    e.a.injectWriteFailures(records = true)
    check e.issue("m-b", "m-a", @[callM1()]).issueErrorOf == CaCode.Internal_error
    check e.revoke("m-b", g.grant_id).revokeErrorOf == CaCode.Internal_error
    e.a.injectWriteFailures()
    check e.sink.drain().len == 0
    check e.get("m-a", g.grant_id).grantOf.statusKind == GrantStatusKind.Active
    check e.evaluate("m-a", @[callM1()]).decisionOf.grant_ids.get == @[g.grant_id]
    e.close()

  test "[CAP-0431] validation before resolution, visibility before policy and state":
    var e = open(policyBytes(everythingFor(@["beta"])))
    # [SPEC CA l.810] A request is validated before anything it names is
    # resolved: a scope of another Runtime naming an unknown instance is
    # unsupported-scope, for an unknown consumer or target too.
    let foreign = meScope("zeta", instance = Opt.some("m-zz"), runtimeId = "rt-9")
    check e.evaluate("m-zz", @[foreign]).errorOf == CaCode.Unsupported_scope
    check e.issue("m-b", "m-zz", @[foreign]).issueErrorOf == CaCode.Unsupported_scope
    check e.evaluate("m-zz", @[callM1()]).errorOf == CaCode.Invalid_request
    check e.issue("m-b", "m-zz", @[callM1()]).issueErrorOf == CaCode.Invalid_request
    # Visibility before policy: a grant hidden from the caller is not found,
    # whether or not policy would let it revoke; a visible one is refused.
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.revoke("m-c", g.grant_id).revokeErrorOf == CaCode.Grant_not_found
    check e.get("m-c", g.grant_id).getErrorOf == CaCode.Grant_not_found
    check e.revoke("m-a", g.grant_id).revokeErrorOf == CaCode.Not_authorised
    # Visibility and policy before state: an expired grant is not found when
    # hidden, refused when visible but not revocable, and not active only for
    # a caller that may revoke it.
    let x = e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now + 5)).grantOf
    e.clock.advance(5)
    check e.revoke("m-c", x.grant_id).revokeErrorOf == CaCode.Grant_not_found
    check e.revoke("m-a", x.grant_id).revokeErrorOf == CaCode.Not_authorised
    check e.revoke("m-b", x.grant_id).revokeErrorOf == CaCode.Grant_not_active
    e.close()

  test "[TXT-0390] [TXT-0393] a refused revocation of a visible grant is not-authorised with a failure record; a repeat returns the grant and writes nothing":
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            inspectRule(
              subject(modules = @["gamma"]), audit = Opt.some(targetSubject(anyone()))
            )
          ]
      )
    )
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.revoke("m-a", g.grant_id).revokeErrorOf == CaCode.Not_authorised
    check e.revoke("m-c", g.grant_id).revokeErrorOf == CaCode.Grant_not_found
    let first = e.revoke("m-b", g.grant_id).grantOf
    check same(e.revoke("m-b", g.grant_id).grantOf, first)
    let rs = e.query("m-c", QueryAuditRequest(grant_id: Opt.some(g.grant_id)))
    var successes, failures = 0
    for r in rs:
      if r.kind == AuditKind.Revoke_grant_success:
        inc successes
      if r.kind == AuditKind.Revoke_grant_failure:
        inc failures
    check successes == 1 # [SPEC CA l.811; G206]
    check failures == 2
    # a repeated protected revocation alike
    let p = e.a.issueProtected(Source, address("m-a"), @[callM1()]).get
    discard e.a.revokeProtected(Source, p.grant_id).get
    check same(
      e.a.revokeProtected(Source, p.grant_id).get, e.get("m-a", p.grant_id).grantOf
    )
    var protectedSuccesses = 0
    for r in e.query("m-c", QueryAuditRequest(grant_id: Opt.some(p.grant_id))):
      if r.kind == AuditKind.Revoke_grant_success:
        inc protectedSuccesses
    check protectedSuccesses == 1
    e.close()

  test "[CAP-0324] [CAP-0325] [CAP-0326] [CAP-0327] [CAP-0328] [CAP-0329] issuers: the caller, or the protected source without a consumer":
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            inspectRule(
              subject(modules = @["gamma"]),
              audit = Opt.some(targetSubject(anyone())),
              grants = Opt.some(targetSubject(anyone())),
            )
          ]
      )
    )
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    check g.issuer.kind == LogosNSCapabilityAuthorityGrantIssuerKind.Module
    check g.issuer.arm_Module.module == address("m-b")
    var raw = toCbor(
      IssueGrantRequest(
        consumer: address("m-b"), target: address("m-a"), scopes: @[callM1()]
      )
    )
    raw.entries.add((cbor("issuer"), cbor("x")))
    check decode(IssueGrantRequest, encodeCbor(raw)).isErr
    let p = e.a.issueProtected("boot.policy", address("m-a"), @[callM1()]).get
    check p.issuer.kind == LogosNSCapabilityAuthorityGrantIssuerKind.Protected_policy
    check p.issuer.arm_Protected_policy.source == "boot.policy"
    check e.a.issueProtected("Not Valid", address("m-a"), @[callM1()]).error.code ==
      CaCode.Invalid_request
    let rs = e.query("m-c", QueryAuditRequest(grant_id: Opt.some(p.grant_id)))
    check rs.len == 1
    check rs[0].arm_Issue_grant_success.consumer.isNone
    e.reopen(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            inspectRule(
              subject(modules = @["gamma"]),
              audit = Opt.some(targetSubject(anyone())),
              grants = Opt.some(targetSubject(anyone())),
            )
          ]
      )
    )
    check same(e.get("m-c", g.grant_id).grantOf.issuer, g.issuer)
    check same(e.get("m-c", p.grant_id).grantOf.issuer, p.issuer)
    e.close()

  test "[CAP-0145] [CAP-0146] [CAP-0147] the caller comes from context: another consumer or caller kind is not-authorised":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let req = IssueGrantRequest(
      consumer: address("m-b"), target: address("m-a"), scopes: @[callM1()]
    )
    check e.a.issueGrant(moduleCaller("m-a"), req).issueErrorOf == CaCode.Not_authorised
    check e.a.issueGrant(systemCaller(), req).issueErrorOf == CaCode.Not_authorised
    check e.a.evaluate(moduleCaller("m-a"), evalRequest("m-a", @[callM1()])).errorOf ==
      CaCode.Not_authorised
    check e.a.getGrant(
      moduleCaller("m-a"), GetGrantRequest(consumer: address("m-b"), grant_id: "g")
    ).getErrorOf == CaCode.Not_authorised
    e.close()

  test "[CAP-0148] [CAP-0011] protected and module grants behave alike":
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[revokeRule(subject(modules = @["beta"]), targetSubject(anyone()))]
      )
    )
    let p = e.a.issueProtected(
      Source, address("m-a"), @[callM1()], Opt.some(e.now + 1_000)
    ).get
    check e.evaluate("m-a", @[callM1()]).decisionOf.grant_ids.get == @[p.grant_id]
    discard e.revoke("m-b", p.grant_id).grantOf
    check e.evaluate("m-a", @[callM1()]).decisionOf.denialOf == DenialKind.Grant_revoked
    let q = e.a.issueProtected(
      Source, address("m-c"), @[callM1()], Opt.some(e.now + 1_000)
    ).get
    discard e.a.revokeProtected(Source, q.grant_id).get
    check e.a.revokeProtected(Source, "g-none").error.code == CaCode.Grant_not_found
    e.close()

  test "[CAP-0336] a grant for one instance never supports another of the same module":
    let facts = fakeFacts()
    check facts.putInstance("m-a2", InstanceFacts(module: "alpha")).isOk
    var e = open(policyBytes(everythingFor(@["beta"])), facts = facts)
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.evaluate("m-a2", @[callM1()]).decisionOf.denialOf == DenialKind.Not_granted
    e.close()

  test "[CAP-0122] [CAP-0252] a grant or decision id in a request field authorizes nothing":
    var e = open(policyBytes(everythingFor(@["beta"]) & @[alphaCalls()]))
    let d = e.evaluate("m-a", @[callM1()]).decisionOf
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.evaluate("m-c", @[callScope(root(M1), route = d.decision_id)]).decisionOf.denialOf ==
      DenialKind.Not_granted
    check e.evaluate("m-c", @[callScope(root(M1), route = g.grant_id)]).decisionOf.denialOf ==
      DenialKind.Not_granted
    e.close()

  test "[IMPL] retention: past the bound the oldest terminal grant goes; with all active issuance is authority-unavailable":
    var limits = AuthorityLimits()
    limits.maxGrants = 3
    var e = open(policyBytes(everythingFor(@["beta"])), limits)
    var ids: seq[string]
    for i in 0 ..< 3:
      ids.add e.issue("m-b", "m-a", @[callM1()]).grantOf.grant_id
    check e.issue("m-b", "m-a", @[callM1()]).issueErrorOf == CaCode.Authority_unavailable
    e.clock.advance(1)
    discard e.revoke("m-b", ids[1]).grantOf
    e.clock.advance(1)
    discard e.revoke("m-b", ids[0]).grantOf
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.get("m-a", ids[1]).getErrorOf == CaCode.Grant_not_found
    check e.get("m-a", ids[0]).grantOf.statusKind == GrantStatusKind.Revoked
    check not (e.dir / GrantsDir / (ids[1] & ".cbor")).fileExists
    e.close()

# D5 ------------------------------------------------------------------------------------

var
  gate: Atomic[bool]
  inSink: Atomic[bool] ## the CA thread is inside `blockSink`

proc blockSink(env: pointer) {.nimcall, gcsafe, raises: [].} =
  inSink.store(true)
  while not gate.load:
    sleep(1)

type ProtectedJob = object
  a: Authority

proc protectedIssue(j: ptr ProtectedJob) {.thread.} =
  discard j.a.issueProtected(Source, address("m-a"), @[callScope(root(M1))])

suite "cap.grants: giving up (D5)":
  test "[IMPL] D5: a module request withdrawn before the CA thread claims it is never processed":
    var limits = AuthorityLimits()
    limits.moduleTimeoutMs = 50
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            inspectRule(
              subject(modules = @["gamma"]), audit = Opt.some(targetSubject(anyone()))
            )
          ]
      ),
      limits,
    )
    gate.store(false)
    inSink.store(false)
    e.sink.hook = blockSink
    var job = ProtectedJob(a: e.a)
    var th: Thread[ptr ProtectedJob]
    createThread(th, protectedIssue, addr job)
    # The CA thread is held inside the sink of the protected issuance: the
    # module request below is never claimed before its 50 ms run out.
    while not inSink.load:
      sleep(1)
    let r = e.issue("m-b", "m-c", @[callM1()])
    check r.issueErrorOf == CaCode.Authority_unavailable
    gate.store(true)
    joinThread(th)
    e.sink.hook = nil
    let rs = e.query("m-c", QueryAuditRequest(target: Opt.some(address("m-c"))))
    check rs.len == 0
    e.close()

# cap.list -------------------------------------------------------------------------------

suite "cap.list: list_grants":
  proc lst(
      e: Env,
      caller: string,
      limit = Opt.none(uint16),
      cursor = Opt.none(string),
      target = Opt.none(Address),
  ): ListGrantsResponse =
    e.a.listGrants(
      moduleCaller(caller),
      ListGrantsRequest(
        consumer: address(caller), limit: limit, cursor: cursor, target: target
      ),
    )

  test "[CAP-0330] [CAP-0134] ascending ids; limit 0 and 1001 are invalid-request":
    var e = open(policyBytes(everythingFor(@["beta"])))
    for i in 0 ..< 4:
      discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    let gs = e.lst("m-a").listOf.grants
    check gs.len == 4
    for i in 1 ..< gs.len:
      check gs[i - 1].grant_id < gs[i].grant_id
    check e.lst("m-a", Opt.some(0'u16)).listErrorOf.code.kind == CaCode.Invalid_request
    check e.lst("m-a", Opt.some(1001'u16)).listErrorOf.code.kind ==
      CaCode.Invalid_request
    e.close()

  test "[CAP-0135] [CAP-0136] [CAP-0333] hidden grants never count":
    var e = open(policyBytes(everythingFor(@["beta"])))
    for i in 0 ..< 5:
      discard e.issue("m-b", "m-a", @[callM1()]).grantOf
      discard e.issue("m-b", "m-c", @[callM1()]).grantOf
    let five = e.lst("m-a", Opt.some(5'u16)).listOf
    check five.grants.len == 5 and five.next_cursor.isNone
    var counts: seq[int]
    var cursor = Opt.none(string)
    while true:
      let page = e.lst("m-a", Opt.some(2'u16), cursor).listOf
      counts.add page.grants.len
      if page.next_cursor.isNone:
        break
      cursor = page.next_cursor
    check counts == @[2, 2, 1]
    e.close()

  test "[CAP-0331] a continuation is live":
    var e = open(policyBytes(everythingFor(@["beta"])))
    var ids: seq[string]
    for i in 0 ..< 3:
      ids.add e.issue("m-b", "m-a", @[callM1()]).grantOf.grant_id
    let page = e.lst("m-a", Opt.some(1'u16)).listOf
    let later = e.issue("m-b", "m-a", @[callM1()]).grantOf
    var seen: seq[string] = @[page.grants[0].grant_id]
    var cursor = page.next_cursor
    while cursor.isSome:
      let p = e.lst("m-a", Opt.some(1'u16), cursor).listOf
      for g in p.grants:
        seen.add g.grant_id
      cursor = p.next_cursor
    check later.grant_id in seen
    check seen.len == 4
    e.close()

  test "[CAP-0334] [CAP-0335] stale, foreign, changed, tampered and pre-restart cursors fail alike":
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[inspectRule(anyone(), grants = Opt.some(targetSubject(anyone())))]
      )
    )
    for i in 0 ..< 3:
      discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    let c = e.lst("m-a", Opt.some(1'u16)).listOf.next_cursor.get
    let bad = e.lst("m-b", Opt.some(1'u16), Opt.some(c)).listErrorOf
    check bad.code.kind == CaCode.Invalid_request
    check e.lst("m-a", Opt.some(2'u16), Opt.some(c)).listErrorOf.same(bad)
    check e
      .lst("m-a", Opt.some(1'u16), Opt.some(c), Opt.some(address("m-a"))).listErrorOf
      .same(bad)
    var tampered = c
    tampered[^2] = (if tampered[^2] == 'A': 'B' else: 'A')
    check e.lst("m-a", Opt.some(1'u16), Opt.some(tampered)).listErrorOf.same(bad)
    check e.lst("m-a", Opt.some(1'u16), Opt.some(c)).kind ==
      LogosNSCapabilityAuthorityListGrantsResponseKind.Map_grants
    e.clock.advance(601_000)
    check e.lst("m-a", Opt.some(1'u16), Opt.some(c)).listErrorOf.same(bad)
    e.clock.advance(-601_000)
    e.reopen(
      policyBytes(
        everythingFor(@["beta"]) &
          @[inspectRule(anyone(), grants = Opt.some(targetSubject(anyone())))]
      )
    )
    check e.lst("m-a", Opt.some(1'u16), Opt.some(c)).listErrorOf.same(bad)
    e.close()

  test "[CAP-0332] responses are cut to the budget, with a cursor":
    var limits = AuthorityLimits()
    limits.responseBudget = 600
    var e = open(policyBytes(everythingFor(@["beta"])), limits)
    for i in 0 ..< 6:
      discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    let page = e.lst("m-a").listOf
    check page.grants.len >= 1 and page.grants.len < 6
    check page.next_cursor.isSome
    e.close()

  test "[CAP-0249] [CAP-0250] [CAP-0262] [CAP-0263] [TXT-0388] visibility: hidden is not found, self sees its own, revoke implies inspect, fields unchanged":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.get("m-c", g.grant_id).getErrorOf == CaCode.Grant_not_found
    check e.get("m-c", "g-unknown").getErrorOf == CaCode.Grant_not_found
    check same(e.get("m-a", g.grant_id).grantOf, g)
    check same(e.get("m-b", g.grant_id).grantOf, g)
    check encode(e.get("m-b", g.grant_id).grantOf).get == encode(g).get
    e.close()

# cap.audit ---------------------------------------------------------------------------

suite "cap.audit: query_audit":
  test "[CAP-0386] equal timestamps come back in reverse recording order":
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))]
      )
    )
    var ids: seq[string]
    for i in 0 ..< 3:
      ids.add e.evaluate("m-a", @[callM1()]).decisionOf.decision_id
    let rs = e.query("m-a")
    check rs.len == 3
    for i in 0 ..< 3:
      check rs[i].decisionId.get == ids[2 - i]
    e.close()

  test "[CAP-0387] since is inclusive, until exclusive; since > until is invalid-request":
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))]
      )
    )
    let t0 = e.now
    discard e.evaluate("m-a", @[callM1()])
    e.clock.advance(10)
    discard e.evaluate("m-a", @[callM1()])
    check e.query(
      "m-a", QueryAuditRequest(since: Opt.some(t0), until: Opt.some(t0 + 10))
    ).len == 1
    check e.query("m-a", QueryAuditRequest(since: Opt.some(t0 + 10))).len == 1
    check e.query("m-a", QueryAuditRequest(since: Opt.some(t0), until: Opt.some(t0))).len ==
      0
    check e.a.queryAudit(
      moduleCaller("m-a"),
      QueryAuditRequest(
        consumer: address("m-a"), since: Opt.some(t0 + 1), until: Opt.some(t0)
      ),
    ).queryErrorOf == CaCode.Invalid_request
    e.close()

  test "[IMPL-DECISION G51] a query_audit result over the response budget keeps the most recent records that fit":
    var limits = AuthorityLimits()
    limits.responseBudget = 1_000
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))]
      ),
      limits,
    )
    var ids: seq[string]
    for i in 0 ..< 20:
      ids.add e.evaluate("m-a", @[callM1()]).decisionOf.decision_id
      e.clock.advance(1)
    let rs = e.query("m-a")
    check rs.len >= 1 and rs.len < 20
    for i in 0 ..< rs.len:
      check rs[i].decisionId.get == ids[19 - i]
    e.close()

  test "[IMPL] at most 1,000 records come back":
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))]
      )
    )
    for i in 0 ..< 1_005:
      discard e.evaluate("m-a", @[callM1()])
    check e.query("m-a").len == 1_000
    e.close()

  test "[CAP-0243] [CAP-0421] [CAP-0419] [CAP-0420] records outside inspect.audit are omitted whole; each decodes as its variant":
    var e = open(
      policyBytes(
        @[
          alphaCalls(),
          inspectRule(
            subject(modules = @["beta"]),
            audit = Opt.some(targetSubject(subject(modules = @["alpha"]))),
          ),
        ]
      )
    )
    discard e.evaluate("m-a", @[callM1()])
    discard e.evaluate("m-c", @[callM1()])
    let rs = e.query("m-b")
    check rs.len == 1
    check rs[0].consumer.get == address("m-a")
    check e.query("m-c").len == 0
    for r in rs:
      check same(decode(AuditRecord, encode(r).get).get, r)
    e.close()

  test "[CAP-0203] a revoke-grant failure names its target only when the grant is visible":
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            inspectRule(
              subject(modules = @["gamma"]), audit = Opt.some(targetSubject(anyone()))
            )
          ]
      )
    )
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.revoke("m-c", g.grant_id) # hidden from m-c
    discard e.revoke("m-a", g.grant_id) # visible to m-a, not revocable
    var hidden, shown = 0
    for r in e.query("m-c", QueryAuditRequest(grant_id: Opt.some(g.grant_id))):
      if r.kind == AuditKind.Revoke_grant_failure:
        if r.arm_Revoke_grant_failure.target.isNone:
          inc hidden
        else:
          inc shown
    check hidden == 1 and shown == 1
    e.close()

  test "[CAP-0271] [CAP-0272] filters may name a retired address":
    var e = open(
      policyBytes(
        @[
          alphaCalls(),
          inspectRule(
            subject(modules = @["beta"]), audit = Opt.some(targetSubject(anyone()))
          ),
        ]
      )
    )
    discard e.evaluate("m-a", @[callM1()])
    check e.facts.removeInstance("m-a").isOk
    check e.query("m-b", QueryAuditRequest(record_consumer: Opt.some(address("m-a")))).len ==
      1
    e.close()

  test "[CAP-0244] [CAP-0264] [CAP-0245] records carry only their schema fields, never the local subject detail":
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            alphaCalls(),
            inspectRule(
              subject(modules = @["gamma"]), audit = Opt.some(targetSubject(anyone()))
            ),
          ]
      )
    )
    discard e.evaluate("m-a", @[callM1()])
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    let allowedKeys = [
      "timestamp", "operation", "outcome", "consumer", "decision_id", "scopes",
      "denial", "error", "target", "grant_id", "commitments",
    ]
    for r in e.query("m-c"):
      let v = toCbor(r)
      for (k, _) in v.entries:
        check k.text in allowedKeys
    e.close()

  test "[CAP-0422] [CAP-0424] [CAP-0425] [CAP-0426] issue_grant with a permission scope records a failure without scopes":
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            inspectRule(
              subject(modules = @["gamma"]), audit = Opt.some(targetSubject(anyone()))
            )
          ]
      )
    )
    var scopes = @[callM1(), permissionScope()]
    sortSet(scopes)
    check e.issue("m-b", "m-a", scopes).issueErrorOf == CaCode.Unknown_permission
    let rs = e.query("m-c")
    check rs.len == 1
    let f = rs[0].arm_Issue_grant_failure
    check f.scopes.isNone
    check f.consumer == address("m-b") and f.target == address("m-a")
    check f.error.kind == CaCode.Unknown_permission
    e.close()

# cap.notify ------------------------------------------------------------------------------

var order: Atomic[int]

type EvalJob = object
  a: Authority
  go: Atomic[bool]
  allowed: Atomic[bool]

var evalJob: EvalJob

proc startEval(env: pointer) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    evalJob.go.store(true)

proc evalThread(j: ptr EvalJob) {.thread.} =
  while not j.go.load:
    sleep(1)
  let r = j.a.evaluateEngine(evalRequest("m-a", @[callScope(root(M1))]))
  j.allowed.store(
    r.isOk and r.get.result.kind == LogosNSCapabilityAuthorityDecisionResultKind.Allow
  )

suite "cap.notify: the engine notification path":
  test "[CAP-0178] [CAP-0180] [CAP-0181] one grant_changed per transition, before the reply, with the state already active":
    var e = open(policyBytes(everythingFor(@["beta"])))
    e.sink.order = addr order
    evalJob.a = e.a
    evalJob.go.store(false)
    evalJob.allowed.store(false)
    e.sink.hook = startEval
    var th: Thread[ptr EvalJob]
    createThread(th, evalThread, addr evalJob)
    let g = e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now + 1_000)).grantOf
    let repliedAt = order.fetchAdd(1)
    check e.sink.notifiedAt.load < repliedAt
    joinThread(th)
    check evalJob.allowed.load
    e.sink.hook = nil
    check e.sink.drain().len == 1
    discard e.revoke("m-b", g.grant_id).grantOf
    check e.sink.drain().len == 1
    discard e.revoke("m-b", g.grant_id).grantOf
    check e.sink.drain().len == 0
    let h = e.issue("m-b", "m-a", @[callM1()], Opt.some(e.now + 1_000)).grantOf
    discard e.sink.drain()
    e.clock.advance(1_000)
    e.a.tick()
    let evs = e.sink.drain()
    check evs.len == 1 and evs[0].grant.grant_id == h.grant_id
    e.close()

  test "[CAP-0182] an evaluation after revoke_grant returned never uses the grant":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    discard e.revoke("m-b", g.grant_id).grantOf
    check not e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    e.close()

  test "[CAP-0179] [CAP-0163] replacePolicy emits one policy_changed with both revisions and no affected_executions; an equal digest changes nothing":
    let p1 = policyBytes(@[alphaCalls()])
    var e = open(p1)
    check e.a.replacePolicy(p1).get == 1
    check e.sink.drain().len == 0
    let p2 = policyBytes(@[alphaCalls(), inspectRule(anyone(), policyChanges = true)])
    check e.a.replacePolicy(p2).get == 2
    let evs = e.sink.drain()
    check evs.len == 1
    check evs[0].kind == aePolicyChanged
    check evs[0].policy.previous_policy_revision == 1
    check evs[0].policy.policy_revision == 2
    check evs[0].policy.affected_executions.isNone
    check e.a.replacePolicy(p2).get == 2
    check e.sink.drain().len == 0
    check e.query("m-a").len == 1
    check e.a.replacePolicy(@[1'u8, 2, 3]).isErr
    e.close()

  test "[IMPL] a failing sink makes every later evaluation authority-unavailable":
    var e = open(policyBytes(everythingFor(@["beta"]) & @[alphaCalls()]))
    e.sink.setFailing(true)
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.evaluate("m-a", @[callM1()]).errorOf == CaCode.Authority_unavailable
    e.close()

# cap.persist ----------------------------------------------------------------------------

suite "cap.persist: state across restarts and failures":
  test "[CAP-0326] [IMPL] a restart keeps grants, issuers, audit order and seq, decision ids and the revision":
    let p = policyBytes(
      everythingFor(@["beta"]) &
        @[
          alphaCalls(),
          inspectRule(
            subject(modules = @["gamma"]),
            audit = Opt.some(targetSubject(anyone())),
            grants = Opt.some(targetSubject(anyone())),
          ),
        ]
    )
    var e = open(p)
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.evaluate("m-a", @[callM1()])
    e.clock.advance(5)
    discard e.revoke("m-b", g.grant_id).grantOf
    let before = e.query("m-c")
    e.reopen(p)
    check e.get("m-c", g.grant_id).grantOf.statusKind == GrantStatusKind.Revoked
    check same(e.query("m-c"), before)
    check e.a.policyRevision == 1
    discard e.evaluate("m-a", @[callM1()])
    let after = e.query("m-c")
    check after.len == before.len + 1
    check after[0].kind == AuditKind.Evaluate_allow
    e.close()

  test "[CAP-0144] [IMPL] an expiry that fell due while the CA was down is recorded once, at expires_at":
    let p = policyBytes(everythingFor(@["beta"]))
    var e = open(p)
    let exp = e.now + 1_000
    let g = e.issue("m-b", "m-a", @[callM1()], Opt.some(exp)).grantOf
    closeAuthority(e.a)
    e.clock.advance(5_000)
    e.a = openTest(e.dir, p, e.facts, e.clock, e.sink.sink)
    e.a.tick()
    var rs = e.query("m-a", QueryAuditRequest(grant_id: Opt.some(g.grant_id)))
    check rs.len == 2
    check rs[0].arm_Grant_expired_success.timestamp == exp
    e.reopen(p)
    e.a.tick()
    rs = e.query("m-a", QueryAuditRequest(grant_id: Opt.some(g.grant_id)))
    check rs.len == 2
    e.close()

  test "[IMPL] a failed write fails closed, evaluation keeps working, and the next success clears it":
    var e = open(policyBytes(everythingFor(@["beta"]) & @[alphaCalls()]))
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.sink.drain()
    e.a.injectWriteFailures(all = true)
    check e.issue("m-b", "m-a", @[callM1()]).issueErrorOf == CaCode.Authority_unavailable
    check e.revoke("m-b", g.grant_id).revokeErrorOf == CaCode.Authority_unavailable
    check e.sink.drain().len == 0
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    e.a.injectWriteFailures()
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.revoke("m-b", g.grant_id).grantOf
    e.close()

  test "[CAP-0438] [CAP-0440] [CAP-0441] [CAP-0442] [CAP-0443] [IMPL-DECISION G376] a decision only after its record is acknowledged; a failed audit write closes evaluation until a write succeeds":
    var limits = AuthorityLimits()
    limits.maxUnwritten = 3
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))]
      ),
      limits,
    )
    # Acknowledged at the append, under the backlog bound: readable at once,
    # before any write.
    e.a.injectWriteFailures(all = true)
    for i in 0 ..< 3:
      check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    check e.query("m-a").len == 3
    # The backlog is full: no decision, and no record past the bound (l.1212).
    check e.evaluate("m-a", @[callM1()]).errorOf == CaCode.Authority_unavailable
    check e.query("m-a").len == 3
    e.a.injectWriteFailures()
    e.a.flushAudit()
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    # One failed write closes evaluation at once; the failure record is still
    # attempted, with the scopes (l.1211).
    e.a.injectWriteFailures(next = 1)
    e.a.flushAudit()
    check e.evaluate("m-a", @[callM1()]).errorOf == CaCode.Authority_unavailable
    let rs = e.query("m-a")
    check rs[0].kind == AuditKind.Evaluate_failure
    check rs[0].arm_Evaluate_failure.scopes.isSome
    # A successful retry opens it again.
    e.a.flushAudit()
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    e.close()

  test "[IMPL-DECISION G376] with audit.records at 1,024 and every write failing, no acknowledged record is dropped: evaluation fails closed at the backlog bound":
    var limits = AuthorityLimits()
    limits.maxUnwritten = 1_100
    var e = open(
      policyBytes(
        @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))],
        records = Opt.some(1_024'u64),
      ),
      limits,
    )
    e.a.injectWriteFailures(all = true)
    let first = e.evaluate("m-a", @[callM1()]).decisionOf.decision_id
    var allowed = 1
    for i in 1 ..< 1_100:
      if e.evaluate("m-a", @[callM1()]).decisionOf.allowed:
        inc allowed
    check allowed == 1_100
    check e.evaluate("m-a", @[callM1()]).errorOf == CaCode.Authority_unavailable
    check e.query("m-a", QueryAuditRequest(decision_id: Opt.some(first))).len == 1
    # Once written, retention drops the oldest segments again.
    e.a.injectWriteFailures()
    e.a.flushAudit()
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    check e.query("m-a", QueryAuditRequest(decision_id: Opt.some(first))).len == 0
    e.close()

  test "[CAP-0437] an admission failure answers the same whatever the audit state":
    var limits = AuthorityLimits()
    limits.maxUnwritten = 3 # the two failure records of the first pass, and one allow
    var e = open(policyBytes(@[alphaCalls()]), limits)
    let b = callScope(root(M1), provider = "p-b")
    let a = callScope(root(M1), provider = "p-a")
    var unordered = @[a, b]
    if isSet(unordered):
      unordered = @[b, a]
    let over = overMaxScopes()
    for full in [false, true]:
      checkpoint $full
      if full:
        e.a.injectWriteFailures(all = true)
        check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
        check e.evaluate("m-a", @[callM1()]).errorOf == CaCode.Authority_unavailable
      check e.evaluate("m-a", unordered).errorOf == CaCode.Invalid_request
      check e.evaluate("m-a", over).errorOf == CaCode.Invalid_request
    e.a.injectWriteFailures()
    e.close()

  test "[IMPL] the start is refused, files unchanged, for a foreign runtime, another contract, a corrupt grant, an unknown format or a held lock (G111)":
    let p = policyBytes(everythingFor(@["beta"]))
    var e = open(p)
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check openAuthority(testConfig(e.dir, p, e.facts, e.clock, e.sink.sink)).error
      .contains("in use")
    closeAuthority(e.a)
    let meta = readFile(e.dir / MetaName)
    check openAuthority(
      testConfig(e.dir, p, e.facts, e.clock, e.sink.sink, runtimeId = "rt-9")
    ).isErr
    check readFile(e.dir / MetaName) == meta
    var m = decode(LcnAsMeta, meta.toOpenArrayByte(0, meta.high)).get
    m.contract = root(9)
    writeFile(e.dir / MetaName, encode(m).get)
    check openAuthority(testConfig(e.dir, p, e.facts, e.clock, e.sink.sink)).error
      .contains("contract")
    var v = toCbor(decode(LcnAsMeta, meta.toOpenArrayByte(0, meta.high)).get)
    for (k, x) in v.entries.mitems:
      if k.text == "format":
        x = cbor("logos-core-nim.authority-state.v2")
    writeFile(e.dir / MetaName, encodeCbor(v))
    check openAuthority(testConfig(e.dir, p, e.facts, e.clock, e.sink.sink)).isErr
    writeFile(e.dir / MetaName, meta)
    writeFile(e.dir / GrantsDir / "g-bad.cbor", "not cbor")
    check openAuthority(testConfig(e.dir, p, e.facts, e.clock, e.sink.sink)).isErr
    check readFile(e.dir / GrantsDir / "g-bad.cbor") == "not cbor"
    removeFile(e.dir / GrantsDir / "g-bad.cbor")
    e.a = openTest(e.dir, p, e.facts, e.clock, e.sink.sink)
    e.close()

  test "[IMPL] C8: the refusal fires only for a really foreign id":
    let p = policyBytes(everythingFor(@["beta"]))
    var e = open(p)
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    e.reopen(p)
    check e.get("m-a", g.grant_id).grantOf.grant_id == g.grant_id
    closeAuthority(e.a)
    check openAuthority(
      testConfig(e.dir, p, e.facts, e.clock, e.sink.sink, runtimeId = "rt-2")
    ).error
      .contains("rt-1")
    e.a = openTest(e.dir, p, e.facts, e.clock, e.sink.sink)
    e.close()

  test "[IMPL] audit is on disk after close, and retention drops whole segments and advances the floor":
    var limits = AuthorityLimits()
    limits.segmentRecords = 4
    let p = policyBytes(
      @[alphaCalls(), inspectRule(anyone(), audit = Opt.some(targetSelf()))],
      records = Opt.some(1_024'u64),
    )
    var e = open(p, limits)
    for i in 0 ..< 1_030:
      discard e.evaluate("m-a", @[callM1()])
    closeAuthority(e.a)
    let m = decode(
      LcnAsMeta,
      readFile(e.dir / MetaName).toOpenArrayByte(0, readFile(e.dir / MetaName).high),
    ).get
    check m.audit_floor > 0
    var onDisk = 0
    for name in walkDir(e.dir / AuditDir, relative = true):
      let data = readFile(e.dir / AuditDir / name.path)
      let s = decode(LcnAsSegment, data.toOpenArrayByte(0, data.high)).get
      check s.first >= m.audit_floor
      onDisk += s.records.len
    check onDisk <= 1_024 and onDisk > 1_024 - 4
    e.a = openTest(e.dir, p, e.facts, e.clock, e.sink.sink, limits)
    check e.query("m-a").len == 1_000
    e.close()

# cap.watch ------------------------------------------------------------------------------

type ObservedChange = LogosNSCapabilityAuthorityObservedChangeEvent

const
  GrantChanged = "logos.capability_authority.grant_changed_event"
  PolicyChanged = "logos.capability_authority.policy_changed_event"
  Observed = "logos.capability_authority.observed_change_event"

proc grantChange(g: Grant): seq[byte] =
  ## The one payload a watcher gets for a change of `g`: the grant alone.
  encode(
    ObservedChange(
      kind: LogosNSCapabilityAuthorityObservedChangeEventKind.Map_grant,
      arm_Map_grant:
        LogosNSCapabilityAuthorityObservedChangeEventARMapGrantMap(grant: g),
    )
  ).get

proc policyChange(at: uint64, previous, current: uint64): seq[byte] =
  ## The one payload a `policy_changes` watcher gets: no `affected_executions`.
  encode(
    ObservedChange(
      kind:
        LogosNSCapabilityAuthorityObservedChangeEventKind.Map_changed_at_policy_revision_previous_policy_revision,
      arm_Map_changed_at_policy_revision_previous_policy_revision: LogosNSCapabilityAuthorityObservedChangeEventARMapChangedAtPolicyRevisionPreviousPolicyRevisionMap(
        changed_at: at, previous_policy_revision: previous, policy_revision: current
      ),
    )
  ).get

proc watchOf(e: Env, instance: string): Watch =
  e.a.watch(moduleCaller(instance), address(instance)).expect("a watch")

proc changes(w: Watch): seq[seq[byte]] =
  while true:
    let c = w.nextChange()
    if c.isNone:
      break
    result.add c.get

proc eventually(cond: proc(): bool {.closure.}, seconds = 10): bool =
  ## Whether `cond` holds within `seconds` (times `Slow`), by the clock.
  let until = getMonoTime() + initDuration(seconds = seconds * Slow)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(1)
  cond()

type ModuleIssueJob = object
  a: Authority

proc moduleIssue(j: ptr ModuleIssueJob) {.thread.} =
  discard j.a.issueGrant(
    moduleCaller("m-b"),
    IssueGrantRequest(
      consumer: address("m-b"), target: address("m-a"), scopes: @[callScope(root(M1))]
    ),
  )

type EngineEvalJob = object
  a: Authority
  done: Atomic[bool]

proc engineEval(j: ptr EngineEvalJob) {.thread.} =
  discard j.a.evaluateEngine(evalRequest("m-a", @[callScope(root(M1))]))
  j.done.store(true)

suite "cap.watch: ordinary change observation on the CA thread":
  test "[CAP-0364] [CAP-0145] a watch is a module caller's, as itself":
    var e = open(policyBytes(everythingFor(@["beta"])))
    check e.a.watch(systemCaller(), address("m-a")).error == CaCode.Not_authorised
    check e.a.watch(moduleCaller("m-a"), address("m-b")).error == CaCode.Not_authorised
    check e.a.watchCount == 0
    e.close()

  test "[CAP-0372] [CAP-0373] [CAP-0374] [CAP-0377] [CAP-0378] a watcher gets the changes it may see, whole, under the policy of each change":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let w = e.watchOf("m-a")
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    discard e.issue("m-b", "m-c", @[callM1()]).grantOf # not m-a's to see
    check w.changes == @[grantChange(g)]
    let r = e.revoke("m-b", g.grant_id).grantOf
    check w.changes == @[grantChange(r)]
    # Without its inspect rule, m-a sees no further change of its own grants.
    check e.a.replacePolicy(policyBytes(everythingFor(@["beta"])[0 .. 1])).get == 2
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check w.changes.len == 0
    e.a.unwatch(w)
    check e.a.watchCount == 0
    e.close()

  test "[CAP-0379] a policy change goes only to policy_changes inspectors, without affected_executions":
    let rules =
      everythingFor(@["beta"]) &
      @[inspectRule(subject(modules = @["gamma"]), policyChanges = true)]
    var e = open(policyBytes(rules))
    let wa = e.watchOf("m-a")
    let wc = e.watchOf("m-c")
    check e.a.replacePolicy(policyBytes(rules & @[alphaCalls()])).get == 2
    check wa.changes.len == 0
    check wc.changes == @[policyChange(e.now, 1, 2)]
    e.a.unwatch(wa)
    e.a.unwatch(wc)
    e.close()

  test "[CAP-0370] [CAP-0371] equivalent watches get identical payloads, with no watch id":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let w1 = e.watchOf("m-a")
    let w2 = e.watchOf("m-a")
    let g = e.issue("m-b", "m-a", @[callM1()]).grantOf
    let one = w1.changes
    check one == @[grantChange(g)]
    check w2.changes == one
    e.a.unwatch(w1)
    e.a.unwatch(w2)
    e.close()

  test "[CAP-0380] [CAP-0383] 64 watches in all and 8 per consumer; past either, authority-unavailable":
    check AuthorityLimits().maxWatches == 64
    check AuthorityLimits().watchesPerConsumer == 8
    check AuthorityLimits().watchQueue == 256
    let facts = fakeFacts()
    for i in 0 .. 8:
      check facts.putInstance("w" & $i, InstanceFacts(module: "alpha")).isOk
    var e = open(policyBytes(everythingFor(@["beta"])), facts = facts)
    var ws: seq[Watch]
    for i in 0 .. 7:
      for k in 0 .. 7:
        ws.add e.watchOf("w" & $i)
    check e.a.watchCount == 64
    check e.a.watch(moduleCaller("w8"), address("w8")).error ==
      CaCode.Authority_unavailable
    e.a.unwatch(ws.pop())
    check e.a.watch(moduleCaller("w0"), address("w0")).error ==
      CaCode.Authority_unavailable
    ws.add e.watchOf("w8")
    check e.a.watchCount == 64
    for w in ws:
      e.a.unwatch(w)
    check e.a.watchCount == 0
    e.close()

  test "[CAP-0382] [CAP-0383] [CAP-0385] a change that does not fit overflows the watch without blocking; the sink still gets every event":
    var limits = AuthorityLimits()
    limits.watchQueue = 2
    var e = open(policyBytes(everythingFor(@["beta"])), limits)
    let w1 = e.watchOf("m-a")
    let w2 = e.watchOf("m-a")
    for i in 0 .. 2:
      discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check w1.overflowed and w2.overflowed
    check e.sink.drain().len == 3
    discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check e.sink.drain().len == 1
    check w1.changes.len == 2
    e.a.unwatch(w1)
    e.a.unwatch(w2)
    e.close()

  test "[CAP-0382] with the module inbox full and a watch overflowing, engine evaluation is taken first":
    var limits = AuthorityLimits()
    limits.watchQueue = 1
    limits.moduleQueue = 2
    var e = open(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            alphaCalls(),
            inspectRule(
              subject(modules = @["gamma"]), audit = Opt.some(targetSubject(anyone()))
            ),
          ]
      ),
      limits,
    )
    let w = e.watchOf("m-a")
    for i in 0 .. 1:
      discard e.issue("m-b", "m-a", @[callM1()]).grantOf
    check w.overflowed
    # The CA thread is held inside the sink of a protected issuance.
    gate.store(false)
    inSink.store(false)
    e.sink.hook = blockSink
    var pjob = ProtectedJob(a: e.a)
    var pth: Thread[ptr ProtectedJob]
    createThread(pth, protectedIssue, addr pjob)
    while not inSink.load:
      sleep(1)
    # Two module requests fill the module inbox; a third is refused at once.
    var mjob = ModuleIssueJob(a: e.a)
    var mth: array[2, Thread[ptr ModuleIssueJob]]
    for t in mth.mitems:
      createThread(t, moduleIssue, addr mjob)
    check eventually(
      proc(): bool =
        e.a.queuedRequests.module == 2
    )
    check e.issue("m-b", "m-a", @[callM1()]).issueErrorOf == CaCode.Authority_unavailable
    var ejob = EngineEvalJob(a: e.a)
    var eth: Thread[ptr EngineEvalJob]
    createThread(eth, engineEval, addr ejob)
    check eventually(
      proc(): bool =
        e.a.queuedRequests.engine == 1
    )
    gate.store(true)
    joinThread(pth)
    joinThread(eth)
    for t in mth.mitems:
      joinThread(t)
    e.sink.hook = nil
    # Newest first: the module issuances were recorded after the evaluation.
    var kinds: seq[LogosNSCapabilityAuthorityAuditRecordKind]
    for r in e.query("m-c"):
      kinds.add r.kind
    check kinds[0 .. 3] ==
      @[
        LogosNSCapabilityAuthorityAuditRecordKind.Issue_grant_success,
        LogosNSCapabilityAuthorityAuditRecordKind.Issue_grant_success,
        LogosNSCapabilityAuthorityAuditRecordKind.Evaluate_allow,
        LogosNSCapabilityAuthorityAuditRecordKind.Issue_grant_success,
      ]
    e.a.unwatch(w)
    e.close()

  test "[IMPL] closing the authority ends every watch; the watch is then freed without it":
    var e = open(policyBytes(everythingFor(@["beta"])))
    let w = e.watchOf("m-a")
    check not w.isEnded
    closeAuthority(e.a)
    check w.isEnded
    e.a.unwatch(w)
    freeChannelSink(e.sink)
    freeClock(e.clock)
    freeSharedFacts(e.facts)

# cap.provider ---------------------------------------------------------------------------

type CaEnv = object
  dir: string
  facts: SharedFacts
  clock: Clock
  ctx: ptr LogosModuleContext

proc wiring(c: CaEnv, policy: seq[byte], limits = AuthorityLimits()): AuthorityWiring =
  AuthorityWiring(
    policy: policy, runtimeId: Rt, facts: c.facts, clock: c.clock, limits: limits
  )

proc openCa(policy: seq[byte], limits = AuthorityLimits(), publish = true): CaEnv =
  result.dir = freshDir()
  result.facts = fakeFacts()
  result.clock = newTestClock()
  doAssert wireAuthority(result.dir, result.wiring(policy, limits)).isOk
  let r = newCa(result.dir, publish)
  doAssert r.isOk, "the CA starts: " & r.error.message.get(r.error.reason)
  result.ctx = r.get

proc close(c: var CaEnv) =
  caDestroy(c.ctx)
  unwireAuthority(c.dir)
  freeClock(c.clock)
  freeSharedFacts(c.facts)

proc call[Q, T](c: CaEnv, bare: string, request: Q, _: typedesc[T]): T =
  ## One call on this thread, as whoever `actAs` last named.
  T.decode(callCa(c.ctx, bare, encode(request).get)).get

proc issue(c: CaEnv, issuer, target: string, scopes: seq[Scope]): IssueGrantResponse =
  actAs(issuer)
  c.call(
    "issue_grant",
    IssueGrantRequest(
      consumer: address(issuer), target: address(target), scopes: scopes
    ),
    IssueGrantResponse,
  )

proc revoke(c: CaEnv, caller, gid: string): RevokeGrantResponse =
  actAs(caller)
  c.call(
    "revoke_grant",
    RevokeGrantRequest(consumer: address(caller), grant_id: gid),
    RevokeGrantResponse,
  )

proc evaluate(c: CaEnv, consumer: string, scopes: seq[Scope]): EvaluateResponse =
  actAs("", system = true)
  c.call("evaluate", evalRequest(consumer, scopes), EvaluateResponse)

proc watchOutcome(bytes: openArray[byte]): Opt[CaCode] =
  ## none for `{}`, else the error's code.
  let r = WatchChangesResponse.decode(bytes).get
  if r.kind == LogosNSCapabilityAuthorityWatchChangesResponseKind.Map:
    Opt.none(CaCode)
  else:
    Opt.some(r.arm_Map_error.error.code.kind)

# A watch_changes body on its own thread, as an asynchronous call runs it.

const Watchers = ["m-a", "m-b", "m-c"]

type WatchJob = object
  ctx: ptr LogosModuleContext
  who: int
  hook: ScopedHook
  cancel: Atomic[bool]
  done: Atomic[bool]
  response: array[256, byte]
  responseLen: int

var
  hookCtx: ptr LogosModuleContext
  hookHold: Atomic[bool] ## `holdHook` waits while it is true
  hookHeld: Atomic[int]
  reentered: Atomic[int] ## `get_grant` successes from inside a publication

proc reenter() {.nimcall, gcsafe, raises: [].} =
  ## [CAP-0375] Calls `get_grant` for the change being published, from inside
  ## the publication.
  var gid = ""
  for p in publications():
    if p.scoped:
      let c = ObservedChange.decode(p.payload)
      if c.isOk and
          c.get.kind == LogosNSCapabilityAuthorityObservedChangeEventKind.Map_grant:
        gid = c.get.arm_Map_grant.grant.grant_id
  if gid.len == 0:
    return
  let r = GetGrantResponse.decode(
    callCa(
      hookCtx,
      "get_grant",
      encode(GetGrantRequest(consumer: address("m-a"), grant_id: gid)).get,
    )
  )
  if r.isOk and r.get.kind == LogosNSCapabilityAuthorityGetGrantResponseKind.Map_grant:
    reentered += 1

proc holdHook() {.nimcall, gcsafe, raises: [].} =
  hookHeld += 1
  while hookHold.load:
    sleep(1)

proc watchBody(j: ptr WatchJob) {.thread.} =
  actAs(
    Watchers[j.who],
    label = "route-" & Watchers[j.who],
    cancel = addr j.cancel,
    scoped = j.hook,
  )
  let r = callCa(
    j.ctx,
    "watch_changes",
    encode(WatchChangesRequest(consumer: address(Watchers[j.who]))).get,
  )
  j.responseLen = min(r.len, j.response.len)
  for i in 0 ..< j.responseLen:
    j.response[i] = r[i]
  j.done.store(true)

proc startWatch(
    c: CaEnv,
    j: var WatchJob,
    t: var Thread[ptr WatchJob],
    who: int,
    hook: ScopedHook = nil,
) =
  let a = authorityFor(c.dir).get
  let before = a.watchCount
  j.ctx = c.ctx
  j.who = who
  j.hook = hook
  j.cancel.store(false)
  j.done.store(false)
  createThread(t, watchBody, addr j)
  check eventually(
    proc(): bool =
      a.watchCount == before + 1
  )

proc outcome(j: var WatchJob): Opt[CaCode] =
  watchOutcome(j.response.toOpenArray(0, j.responseLen - 1))

suite "cap.provider: the module through its services":
  setup:
    clearPublications()

  test "[IMPL] the instance starts only when wired; one wiring per directory; a recovered instance starts again":
    let facts = fakeFacts()
    var clock = newTestClock()
    let p = policyBytes(everythingFor(@["beta"]))
    let w = AuthorityWiring(policy: p, runtimeId: Rt, facts: facts, clock: clock)
    check newCa("").error.code == ecModule
    let dir = freshDir()
    check newCa(dir).error.code == ecModule
    check wireAuthority("", w).isErr
    var nofacts = w
    nofacts.facts = nil
    check wireAuthority(dir, nofacts).isErr
    var noid = w
    noid.runtimeId = ""
    check wireAuthority(dir, noid).isErr
    check wireAuthority(dir, w).isOk
    check wireAuthority(dir, w).isErr
    let first = newCa(dir).get
    check authorityFor(dir).isSome
    check newCa(dir).error.code == ecModule # G111: one instance per state directory
    caDestroy(first)
    check authorityFor(dir).isNone
    let again = newCa(dir).get
    caDestroy(again)
    unwireAuthority(dir)
    check newCa(dir).error.code == ecModule
    freeClock(clock)
    freeSharedFacts(facts)

  test "[CAP-0358] [CAP-0366] [CAP-0367] grant_changed and policy_changed go through the publish callback once per transition, holding only their fields; observed_change never does":
    let rules = everythingFor(@["beta"])
    var c = openCa(policyBytes(rules))
    clearPublications()
    let g = c.issue("m-b", "m-a", @[callM1()]).grantOf
    var ps = publications()
    check ps.len == 1
    check ps[0].event == GrantChanged and not ps[0].scoped
    check ps[0].payload ==
      encode(LogosNSCapabilityAuthorityGrantChangedEvent(grant: g)).get
    clearPublications()
    let a = authorityFor(c.dir).get
    check a.replacePolicy(policyBytes(rules & @[alphaCalls()])).get == 2
    ps = publications()
    check ps.len == 1
    check ps[0].event == PolicyChanged and not ps[0].scoped
    check ps[0].payload ==
      encode(
        PolicyChangedEvent(
          changed_at: uint64(c.clock.wallMs),
          previous_policy_revision: 1,
          policy_revision: 2,
        )
      ).get
    # With a watch running, the change also goes to the watch's scope, and
    # only there as observed_change.
    var j: WatchJob
    var t: Thread[ptr WatchJob]
    c.startWatch(j, t, 0)
    clearPublications()
    let r = c.revoke("m-b", g.grant_id).grantOf
    check eventually(
      proc(): bool =
        publications().len == 2
    )
    ps = publications()
    var plain, scoped: seq[string]
    for p in ps:
      if p.scoped:
        scoped.add p.event
        check p.payload == grantChange(r)
        check p.label == "route-m-a"
      else:
        plain.add p.event
    check plain == @[GrantChanged]
    check scoped == @[Observed]
    j.cancel.store(true)
    joinThread(t)
    check j.outcome.isNone
    c.close()

  test "[IMPL] an instance without a publish callback does not start: the engine path always exists":
    let facts = fakeFacts()
    var clock = newTestClock()
    let dir = freshDir()
    check wireAuthority(
      dir,
      AuthorityWiring(
        policy: policyBytes(everythingFor(@["beta"])),
        runtimeId: Rt,
        facts: facts,
        clock: clock,
      ),
    ).isOk
    check newCa(dir, publish = false).error.code == ecModule
    check authorityFor(dir).isNone
    unwireAuthority(dir)
    freeClock(clock)
    freeSharedFacts(facts)

  test "[CAP-0248] [CAP-0364] [CAP-0146] the caller is the context's: a SYSTEM_SERVICE evaluates and cannot watch; a module evaluates only as itself":
    var c = openCa(policyBytes(everythingFor(@["beta"]) & @[alphaCalls()]))
    check c.evaluate("m-a", @[callM1()]).decisionOf.allowed
    actAs("", system = true)
    check watchOutcome(
      callCa(
        c.ctx,
        "watch_changes",
        encode(WatchChangesRequest(consumer: address("m-a"))).get,
      )
    ) == Opt.some(CaCode.Not_authorised)
    # With no rule or grant naming `evaluate`, not even for itself (G378).
    actAs("m-a")
    check c.call("evaluate", evalRequest("m-a", @[callM1()]), EvaluateResponse).errorOf ==
      CaCode.Not_authorised
    # A payload naming another consumer is refused: the caller is m-a.
    check c.call(
      "issue_grant",
      IssueGrantRequest(
        consumer: address("m-b"), target: address("m-a"), scopes: @[callM1()]
      ),
      IssueGrantResponse,
    ).issueErrorOf == CaCode.Not_authorised
    c.close()

  test "[TXT-0402] [CAP-0248] [IMPL-DECISION G378] a module evaluates for itself only under a rule or grant naming `evaluate`":
    let named = paPattern(
      @[LcnApActionKind.Call],
      contract = crCa,
      access = Opt.some(LcnApAccess(methods: decls(@[declName("evaluate")]))),
    )
    let broad = paPattern(@[LcnApActionKind.Call], contract = crCa)
    var c = openCa(
      policyBytes(
        everythingFor(@["beta"]) & @[alphaCalls()] &
          @[allowRule(subject(modules = @["alpha"]), @[named])]
      )
    )
    let a = authorityFor(c.dir).get
    proc evaluations(who: string): seq[AuditRecord] =
      for r in recordsOf(
        a.queryAudit(moduleCaller(who), QueryAuditRequest(consumer: address(who)))
      ):
        if r.kind in {
          AuditKind.Evaluate_allow, AuditKind.Evaluate_deny, AuditKind.Evaluate_failure
        }:
          result.add r

    # For itself: a decision, and an `evaluate` record.
    actAs("m-a")
    let d =
      c.call("evaluate", evalRequest("m-a", @[callM1()]), EvaluateResponse).decisionOf
    check d.allowed
    var rs = evaluations("m-a")
    check rs.len == 1 and rs[0].kind == AuditKind.Evaluate_allow
    check rs[0].arm_Evaluate_allow.decision_id == d.decision_id
    # For another consumer, or with `execution_renewal`: not-authorised, and
    # no record.
    check c.call("evaluate", evalRequest("m-b", @[callM1()]), EvaluateResponse).errorOf ==
      CaCode.Not_authorised
    var renewal = evalRequest("m-a", @[callM1()])
    renewal.execution_renewal = Opt.some(true)
    check c.call("evaluate", renewal, EvaluateResponse).errorOf == CaCode.Not_authorised
    check evaluations("m-a").len == 1
    # m-b has no rule naming it; a grant naming it is enough.
    actAs("m-b")
    check c.call("evaluate", evalRequest("m-b", @[callM1("p-b")]), EvaluateResponse).errorOf ==
      CaCode.Not_authorised
    let evalCall = callScope(caMethodRoot("evaluate"), caContract())
    discard a.issueProtected(Source, address("m-b"), @[evalCall]).get
    # A decision: scope-denied, as that grant covers the `call` action (G377).
    check c.call("evaluate", evalRequest("m-b", @[callM1("p-b")]), EvaluateResponse).decisionOf.denialOf ==
      DenialKind.Scope_denied
    c.close()
    # Under a rule with an unconstrained method list: the Runtime-path
    # evaluation of the call is denied, and the module may not evaluate.
    c = openCa(policyBytes(everythingFor(@["beta"]) & @[allowRule(anyone(), @[broad])]))
    check c.evaluate("m-a", @[evalCall]).decisionOf.denialOf == DenialKind.Scope_denied
    actAs("m-a")
    check c.call("evaluate", evalRequest("m-a", @[callM1()]), EvaluateResponse).errorOf ==
      CaCode.Not_authorised
    c.close()
    # A broad deny for the caller beside a rule naming it: not-authorised.
    c = openCa(
      policyBytes(
        everythingFor(@["beta"]) &
          @[
            allowRule(subject(modules = @["alpha"]), @[named]),
            denyRule(subject(modules = @["alpha"]), @[broad]),
          ]
      )
    )
    actAs("m-a")
    check c.call("evaluate", evalRequest("m-a", @[callM1()]), EvaluateResponse).errorOf ==
      CaCode.Not_authorised
    c.close()

  test "[IMPL-DECISION G379] a module's scopes name only its own instance and providers: unknown and other targets answer invalid-request alike":
    let named = paPattern(
      @[LcnApActionKind.Call],
      contract = crCa,
      access = Opt.some(LcnApAccess(methods: decls(@[declName("evaluate")]))),
    )
    var c = openCa(
      policyBytes(
        everythingFor(@["beta"]) & @[allowRule(subject(modules = @["alpha"]), @[named])]
      )
    )
    proc stopOn(instance: string): Scope =
      toScope(
        RuntimeControlScope(
          runtime: Rt,
          contract: rcContract(),
          methods: Opt.some(@[rcContractInfo().methods.getOrDefault("stop_module")]),
          instances: Opt.some(@[instance]),
        )
      )

    proc raw(scopes: seq[Scope]): seq[byte] =
      actAs("m-a")
      callCa(c.ctx, "evaluate", encode(evalRequest("m-a", scopes)).get)

    let cases = [
      @[stopOn("m-zz")], # an unknown instance
      @[stopOn("m-b")], # another module's instance
      @[callM1("p-b")], # another module's provider
      @[callM1("p-zz")], # an unknown provider
      @[meScope("beta", Opt.some("m-b"))], # another module's execution
    ]
    let first = raw(cases[0])
    check EvaluateResponse.decode(first).get.errorOf == CaCode.Invalid_request
    for x in cases[1 ..^ 1]:
      check raw(x) == first
    # Its own: a decision, and a wrong module for its own instance stays
    # invalid-request.
    check EvaluateResponse.decode(raw(@[stopOn("m-a")])).get.decisionOf.denialOf ==
      DenialKind.Not_granted
    check EvaluateResponse.decode(raw(@[meScope("alpha", Opt.some("m-a"))])).get.decisionOf.denialOf ==
      DenialKind.Not_granted
    check EvaluateResponse.decode(raw(@[meScope("beta", Opt.some("m-a"))])).get.errorOf ==
      CaCode.Invalid_request
    # A scope naming no provider goes to a decision.
    check EvaluateResponse.decode(raw(@[pa(@[PaActionKind.Discover])])).get.decisionOf.denialOf ==
      DenialKind.Not_granted
    c.close()

  test "[CAP-0375] [CAP-0384] [CAP-0368] [CAP-0369] [CAP-0381] a watch publishes with no CA lock held, and cancellation ends it with {} and no state change":
    var c = openCa(policyBytes(everythingFor(@["beta"])))
    hookCtx = c.ctx
    reentered.store(0)
    var j: WatchJob
    var t: Thread[ptr WatchJob]
    c.startWatch(j, t, 0, reenter)
    let g = c.issue("m-b", "m-a", @[callM1()]).grantOf
    check eventually(
      proc(): bool =
        reentered.load == 1
    )
    # Cancellation with nothing changing is seen by the next poll.
    let before = getMonoTime()
    j.cancel.store(true)
    joinThread(t)
    check getMonoTime() - before < initDuration(seconds = 2 * Slow)
    check j.outcome.isNone
    check authorityFor(c.dir).get.watchCount == 0
    actAs("m-a")
    let now = c.call(
      "get_grant",
      GetGrantRequest(consumer: address("m-a"), grant_id: g.grant_id),
      GetGrantResponse,
    )
    check same(now.grantOf, g)
    c.close()

  test "[CAP-0383] a watch that cannot keep up ends with authority-unavailable; the changes it took stay delivered":
    var limits = AuthorityLimits()
    limits.watchQueue = 1
    var c = openCa(policyBytes(everythingFor(@["beta"])), limits)
    hookHold.store(true)
    hookHeld.store(0)
    var j: WatchJob
    var t: Thread[ptr WatchJob]
    c.startWatch(j, t, 0, holdHook)
    discard c.issue("m-b", "m-a", @[callM1()]).grantOf
    check eventually(
      proc(): bool =
        hookHeld.load == 1
    )
    for i in 0 .. 1:
      discard c.issue("m-b", "m-a", @[callM1()]).grantOf
    hookHold.store(false)
    joinThread(t)
    check j.outcome == Opt.some(CaCode.Authority_unavailable)
    var scoped = 0
    for p in publications():
      if p.scoped:
        inc scoped
    check scoped == 1
    check authorityFor(c.dir).get.watchCount == 0
    c.close()

# cap.remote ----------------------------------------------------------------------------

const
  R2 = "2b1c7a7e-5a1f-4c3e-9d2a-0f6b8e4d1c2a" ## an enrolled Runtime
  R3 = "7d0e3f1a-9b2c-4a5d-8e6f-1a2b3c4d5e6f" ## a Runtime with no active enrollment
  R1 = "c0ffee00-1234-4abc-8def-0123456789ab" ## a UUIDv4 id for this Runtime

proc field(v: CborValue, name: string): CborValue =
  for e in v.entries:
    if e.key.kind == ckText and e.key.text == name:
      return e.value
  nil

proc withSelectorRuntimes(p: LcnAuthorityPolicy, id: string): seq[byte] =
  ## The first rule's first scope, a provider-access scope with `providers`,
  ## given `runtimes` there too: what `lcn.ap_selector` has no field for.
  let v = toCbor(p)
  let providers = v.field("rules").items[0].field("scopes").items[0].field("providers")
  providers.entries.add((cbor("runtimes"), cborArray(cbor(id))))
  encodeCbor(v)

proc remoteEval(
    e: Env, instance, runtime: string, scopes: seq[Scope]
): EvaluateResponse =
  e.a.evaluate(
    systemCaller(),
    EvaluateRequest(consumer: address(instance, runtime), scopes: scopes),
  )

proc remoteIssue(
    e: Env, issuer, instance, runtime: string, scopes: seq[Scope]
): IssueGrantResponse =
  e.a.issueGrant(
    moduleCaller(issuer),
    IssueGrantRequest(
      consumer: address(issuer), target: address(instance, runtime), scopes: scopes
    ),
  )

proc mentions[T](x: T, id: string): bool =
  let b = encodeCbor(toCbor(x))
  var text = newString(b.len)
  for i, c in b:
    text[i] = char(c)
  id in text

proc anyCall(): LcnApScope =
  paPattern(@[LcnApActionKind.Call], exact = testContract())

suite "cap.remote: forwarded consumers [IMPL-DECISION G415]":
  test "[IMPL-DECISION G415] runtimes: lowercase UUIDv4s, never this Runtime's own, never beside modules, signers or packages, never empty, and only in subjects":
    proc load(rules: seq[LcnApRule], runtimeId = R1): bool =
      loadPolicy(policyBytes(rules), NoProfile, runtimeId).isOk

    check load(@[allowRule(subject(runtimes = @[R2]), @[anyCall()])])
    check load(
      @[allowRule(subject(runtimes = @[R2], instances = @["x"]), @[anyCall()])]
    )
    check not load(@[allowRule(subject(runtimes = @["rt-9"]), @[anyCall()])])
    check not load(@[allowRule(subject(runtimes = @[R2.toUpperAscii]), @[anyCall()])])
    check not load(@[allowRule(subject(runtimes = @[R1]), @[anyCall()])])
    check load(@[allowRule(subject(runtimes = @[R1]), @[anyCall()])], runtimeId = Rt)
    for s in [
      subject(runtimes = @[R2], modules = @["alpha"]),
      subject(runtimes = @[R2], signers = @[gammaSigner()]),
      subject(runtimes = @[R2], packages = @["pkg"]),
    ]:
      check not load(@[allowRule(s, @[anyCall()])])
    # issue, revoke and inspect targets are subjects too
    check not load(
      @[
        revokeRule(
          subject(modules = @["beta"]), targetSubject(subject(runtimes = @[R1]))
        )
      ]
    )
    check load(
      @[
        inspectRule(
          anyone(), grants = Opt.some(targetSubject(subject(runtimes = @[R2])))
        )
      ]
    )
    var empty = policyValue(@[allowRule(subject(runtimes = @[R2]), @[anyCall()])])
    empty.rules[0].arm_lcn_Ap_allow.subject.runtimes = Opt.some(newSeq[string]())
    check loadPolicy(encode(empty).get, NoProfile, R1).isErr
    # a provider selector names this Runtime's providers: no runtimes there
    let sel = policyValue(
      @[
        allowRule(
          anyone(),
          @[
            paPattern(
              @[LcnApActionKind.Call],
              exact = testContract(),
              providers = Opt.some(subject(instances = @["m-a"])),
            )
          ],
        )
      ]
    )
    check loadPolicy(encode(sel).get, NoProfile, R1).isOk
    check loadPolicy(withSelectorRuntimes(sel, R2), NoProfile, R1).isErr

  test "[IMPL-DECISION G415] a forwarded consumer is matched only by a subject naming its Runtime, while that Runtime is enrolled":
    var e = open(
      policyBytes(
        @[
          allowRule(anyone(), @[anyCall()]),
          allowRule(subject(runtimes = @[R2], instances = @["x"]), @[anyCall()]),
        ]
      ),
      enrolled = @[R2],
    )
    # {} matches every local instance and no forwarded consumer
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    check e.remoteEval("x", R2, @[callM1()]).decisionOf.allowed
    check e.remoteEval("y", R2, @[callM1()]).decisionOf.denialOf ==
      DenialKind.Not_granted
    # a Runtime with no active enrollment: its consumer is unknown (CA l.76)
    check e.remoteEval("x", R3, @[callM1()]).errorOf == CaCode.Invalid_request
    e.close()

  test "[IMPL-DECISION G415] a Runtime named without an enrollment loads, matches nothing, and the load report names it":
    let bytes = policyBytes(
      @[
        allowRule(subject(runtimes = @[R2, R3]), @[anyCall()]),
        inspectRule(
          anyone(), audit = Opt.some(targetSubject(subject(runtimes = @[R3])))
        ),
      ]
    )
    let p = loadPolicy(bytes, NoProfile, R1).get
    let report = p.unenrolledRuntimes(@[R2])
    check report.len == 2
    check "rules[0].subject names Runtime " & R3 in report[0]
    check "rules[1].audit names Runtime " & R3 in report[1]
    check p.unenrolledRuntimes(@[R2, R3]).len == 0
    var e = open(bytes, enrolled = @[R2])
    check e.remoteEval("x", R2, @[callM1()]).decisionOf.allowed
    check e.remoteEval("x", R3, @[callM1()]).errorOf == CaCode.Invalid_request
    e.close()

  test "[IMPL-DECISION G415] a grant targets a consumer of an enrolled Runtime without the instance being checked; of any other Runtime it is invalid-request":
    var e = open(
      policyBytes(
        @[
          issueRule(
            subject(modules = @["beta"]),
            targetSubject(subject(runtimes = @[R2])),
            @[paPattern(@[LcnApActionKind.Call], exact = testContract())],
          ),
          inspectRule(
            anyone(),
            grants = Opt.some(targetSubject(anyone())),
            audit = Opt.some(targetSubject(anyone())),
          ),
        ]
      ),
      enrolled = @[R2],
    )
    let g = e.remoteIssue("m-b", "x", R2, @[callM1()]).grantOf
    check g.target.runtime_instance_id == R2
    let d = e.remoteEval("x", R2, @[callM1()]).decisionOf
    check d.allowed and d.grant_ids.get == @[g.grant_id]
    check e.remoteEval("y", R2, @[callM1()]).decisionOf.denialOf ==
      DenialKind.Not_granted
    check e.remoteIssue("m-b", "x", R3, @[callM1()]).issueErrorOf ==
      CaCode.Invalid_request
    # a local target is not covered by a target naming R2 only
    check e.issue("m-b", "m-a", @[callM1()]).kind ==
      LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_denial
    # (x): an inspect target naming no Runtime covers forwarded consumers' records
    var seen = 0
    for r in e.query("m-c"):
      if r.mentions(R2):
        inc seen
    check seen >= 2 # the issue and the evaluations of x and y
    let listed = e.a.listGrants(
      moduleCaller("m-c"), ListGrantsRequest(consumer: address("m-c"))
    ).listOf
    check listed.grants.len == 1
    e.close()

  test "[IMPL-DECISION G415] an inspect target naming a Runtime covers only that Runtime's consumers":
    var e = open(
      policyBytes(
        @[
          allowRule(subject(runtimes = @[R2]), @[anyCall()]),
          allowRule(anyone(), @[anyCall()]),
          inspectRule(
            subject(instances = @["m-c"]),
            audit = Opt.some(targetSubject(subject(runtimes = @[R2]))),
          ),
          inspectRule(
            subject(instances = @["m-b"]), audit = Opt.some(targetSubject(anyone()))
          ),
        ]
      ),
      enrolled = @[R2],
    )
    check e.remoteEval("x", R2, @[callM1()]).decisionOf.allowed
    check e.evaluate("m-a", @[callM1()]).decisionOf.allowed
    let narrow = e.query("m-c")
    check narrow.len == 1 and narrow[0].mentions(R2)
    let wide = e.query("m-b")
    check wide.len == 2
    e.close()
