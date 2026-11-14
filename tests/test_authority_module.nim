## The Capability Authority as a direct-mode module in the engine (step 8a.2;
## DECISIONS I84): the `direct_static` instance `logos_capability_authority`
## on a state assignment, wired with `wireAuthority` before it starts, and
## called over routes by the route fixture's consumer module. The allow-all
## authorizer is still the Runtime's decision source: step 8b replaces it with
## this instance, intercepts its `grant_changed` and `policy_changed`, and
## checks a routed call's `consumer` before dispatch.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime]
# The CA contract repeats the Runtime types the Runtime Control contract
# declares: the route fixture uses Runtime Control's.
import ../src/logos_core/authority/provider except
  LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
  LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
  LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
  LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
import ./support/authfixture except
  LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
  LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
  LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
  LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "authority_module" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

proc eventually(cond: proc(): bool {.closure.}): bool =
  ## The route fixture's `waitUntil`, with its 10 s scaled by `Slow` for
  ## sanitizer builds.
  waitUntil(cond, 10 * Slow)

# The CA instance ------------------------------------------------------------------------

const
  CaModule = "logos_capability_authority"
  CaAssignment = "ca-state"
  GrantChanged = "logos.capability_authority.grant_changed_event"
  Observed = "logos.capability_authority.observed_change_event"
  M1 = 10'u8

let
  caDocs = caDocuments()
  caSet = acceptContractSet(
    caDocs[0], caDocs[1], caDocs[2], AcceptOptions(system: true)
  ).tryGet
  caRoot = caSet.primary.root
  caSchema = encodeCbor(schemaResponse(caSet, caRoot).tryGet)

proc caRecord(): ModuleRecord =
  ModuleRecord(
    module: CaModule,
    strategy: stDirectStatic,
    binding: CaModule,
    primaryContract: Opt.some(caRoot),
    stateAssignment: Opt.some(CaAssignment),
  )

proc clientPolicy(): seq[byte] =
  ## The client module issues grants on the test contract to anyone and
  ## revokes what it issued; everyone inspects the grants targeting it and its
  ## own audit.
  policyBytes(
    @[
      issueRule(
        subject(modules = @["client_module"]),
        targetSubject(anyone()),
        @[paPattern(@[LcnApActionKind.Call], exact = testContract())],
      ),
      revokeRule(subject(modules = @["client_module"]), targetIssued()),
      inspectRule(
        anyone(), grants = Opt.some(targetSelf()), audit = Opt.some(targetSelf())
      ),
    ]
  )

type CaHost = object
  ## One engine run's CA inputs: the state root, and the facts and clock the
  ## wiring hands the instance.
  root: string
  facts: SharedFacts
  clock: Clock

var hosts = 0

proc newHost(root = ""): CaHost =
  inc hosts
  result.root = (if root.len > 0: root else: work / ("h" & $hosts))
  result.facts = fakeFacts()
  for c in ["c1", "c2"]:
    doAssert result.facts.putInstance(c, InstanceFacts(module: "client_module")).isOk
  result.clock = newTestClock()

proc caDir(h: CaHost): string =
  h.root / "state" / CaAssignment

proc wire(h: CaHost, policy = clientPolicy()) =
  doAssert wireAuthority(
    h.caDir,
    AuthorityWiring(policy: policy, runtimeId: Rt, facts: h.facts, clock: h.clock),
  ).isOk

proc free(h: var CaHost) =
  unwireAuthority(h.caDir)
  freeClock(h.clock)
  freeSharedFacts(h.facts)

proc caConfig(h: CaHost, store = false): EngineConfig =
  result = config(extra = @[caStaticRegistration()])
  result.runtimeInstanceId = Rt
  # A stop here waits for watch bodies, which a loaded host may hold up.
  result.stopDeadline = initDuration(seconds = 30)
  result.stateRoot = Opt.some(h.root / "state")
  if store:
    result.storeDir = Opt.some(h.root / "store")

proc authority(h: CaHost): Authority =
  authorityFor(h.caDir).get

# Calls over a route -----------------------------------------------------------------------

proc caRoute(rc: ptr LogosRuntimeControlBinding, key: string): LogosRouteHandle =
  let r = rc.establish(key, root = caRoot)
  check r.code == ecOk
  let (code, h) =
    rc.materialize(r.routesOf.routes[0].route, root = caRoot, schema = caSchema)
  check code == ecOk
  h

proc ask[Q, T](h: var LogosRouteHandle, bare: string, request: Q, _: typedesc[T]): T =
  let r = h.raw(bare, encode(request).get)
  doAssert r.code == ecOk, bare & ": " & $r.code & " " & r.message
  T.decode(r.response).get

proc grantOf(r: IssueGrantResponse): Grant =
  doAssert r.kind == LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_grant, $r.kind
  r.arm_Map_grant.grant

proc issueErrorOf(r: IssueGrantResponse): CaCode =
  doAssert r.kind == LogosNSCapabilityAuthorityIssueGrantResponseKind.Map_error, $r.kind
  r.arm_Map_error.error.code.kind

proc same[T](a, b: T): bool =
  encodeCbor(toCbor(a)) == encodeCbor(toCbor(b))

proc issueReq(consumer, target: string): IssueGrantRequest =
  IssueGrantRequest(
    consumer: address(consumer), target: address(target), scopes: @[callScope(root(M1))]
  )

proc grantChange(g: Grant): seq[byte] =
  encode(
    LogosNSCapabilityAuthorityObservedChangeEvent(
      kind: LogosNSCapabilityAuthorityObservedChangeEventKind.Map_grant,
      arm_Map_grant:
        LogosNSCapabilityAuthorityObservedChangeEventARMapGrantMap(grant: g),
    )
  ).get

# Event handlers ------------------------------------------------------------------------

const MaxPayload = 2048

type Heard = object
  count: Atomic[int]
  len: Atomic[int]
  payload: array[MaxPayload, byte]

var heard: array[2, Heard]

proc onEvent(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr Heard](userData)
  let n = min(int(len), MaxPayload)
  for i in 0 ..< n:
    s.payload[i] = data[i]
  s.len.store(n)
  s.count += 1

proc payloadOf(s: var Heard): seq[byte] =
  s.payload[0 ..< s.len.load]

proc listen(h: var LogosRouteHandle, event: string, slot: int): LogosSubscriptionId =
  heard[slot].count.store(0)
  heard[slot].len.store(0)
  check toResult(
    h.vtable.subscribe(addr h, cstring(event), onEvent, addr heard[slot], addr result)
  ).code == ecOk

# Asynchronous calls ---------------------------------------------------------------------

type Done = object
  count: Atomic[int]
  code: Atomic[int]

var done: Done

proc onComplete(
    userData: pointer,
    r: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr Done](userData)
  if not owner.release.isNil:
    owner.release(owner.state)
  d.code.store(int(r.code))
  d.count += 1

proc startAsync(
    h: var LogosRouteHandle, name: string, params: openArray[byte]
): LogosAsyncCall =
  done.count.store(0)
  done.code.store(-1)
  var o = LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion, structSize: csize_t(sizeof(LogosAsyncOptions))
  )
  var cb = LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onComplete,
    userData: addr done,
  )
  let r = h.vtable.prepareCall(
    addr h,
    cstring(name),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr o,
    addr cb,
    addr result,
  )
  check toResult(r).code == ecOk
  result.vtable.submit(addr result)

# Tests ------------------------------------------------------------------------------------

suite "cap.module: the Capability Authority as a direct-mode module":
  test "[CAP-0003] [CAP-0004] [CAP-0005] the CA is a Runtime-known direct_static instance with a provider record, a lifecycle and a state directory":
    var h = newHost()
    h.wire()
    let e = newEngine(h.caConfig)
    let v = e.started(caRecord(), "ca")
    check v.state == msReady
    check v.module == CaModule
    check v.stateAssignment == Opt.some(CaAssignment)
    check v.primaryContract == Opt.some(caRoot)
    check v.provider and v.providerId.len > 0
    check h.caDir.dirExists
    check authorityFor(h.caDir).isSome
    check e.stop("ca").tryGet.state == msUnloaded
    check authorityFor(h.caDir).isNone
    # The wiring stays: a later attempt starts again on the same state.
    check e.start("ca").tryGet.state == msReady
    check authorityFor(h.caDir).isSome
    e.finish()
    check authorityFor(h.caDir).isNone
    h.free()

  test "[CAP-0146] [CAP-0323] [CAP-0330] a client calls the CA over a route; issuer and consumer are its address from context":
    var h = newHost()
    h.wire()
    let e = newEngine(h.caConfig)
    discard e.started(caRecord(), "ca")
    let (_, rc) = e.startClient("c1")
    var r = rc.caRoute("ca")
    let g = r.ask("issue_grant", issueReq("c1", "c2"), IssueGrantResponse).grantOf
    check g.target == address("c2")
    check g.issuer.kind == LogosNSCapabilityAuthorityGrantIssuerKind.Module
    check g.issuer.arm_Module.module == address("c1")
    let got = r.ask(
      "get_grant",
      GetGrantRequest(consumer: address("c1"), grant_id: g.grant_id),
      GetGrantResponse,
    )
    check got.kind == LogosNSCapabilityAuthorityGetGrantResponseKind.Map_grant
    check same(got.arm_Map_grant.grant, g)
    let listed = r.ask(
      "list_grants", ListGrantsRequest(consumer: address("c1")), ListGrantsResponse
    )
    check listed.kind == LogosNSCapabilityAuthorityListGrantsResponseKind.Map_grants
    check listed.arm_Map_grants.grants.mapIt(it.grant_id) == @[g.grant_id]
    let revoked = r.ask(
      "revoke_grant",
      RevokeGrantRequest(consumer: address("c1"), grant_id: g.grant_id),
      RevokeGrantResponse,
    )
    check revoked.kind == LogosNSCapabilityAuthorityRevokeGrantResponseKind.Map_grant
    let audit = r.ask(
      "query_audit", QueryAuditRequest(consumer: address("c1")), QueryAuditResponse
    )
    check audit.kind == LogosNSCapabilityAuthorityQueryAuditResponseKind.Map_records
    check audit.arm_Map_records.records.mapIt(it.kind) ==
      @[
        LogosNSCapabilityAuthorityAuditRecordKind.Revoke_grant_success,
        LogosNSCapabilityAuthorityAuditRecordKind.Issue_grant_success,
      ]
    r.release()
    e.finish()
    h.free()

  test "[CAP-0248] [CAP-0365] [IMPL] a client's evaluate is not-authorised and leaves no record; a payload naming another consumer is refused before dispatch":
    var h = newHost()
    h.wire()
    let e = newEngine(h.caConfig)
    discard e.started(caRecord(), "ca")
    let (_, rc) = e.startClient("c1")
    var r = rc.caRoute("ca")
    let ev =
      r.ask("evaluate", evalRequest("c1", @[callScope(root(M1))]), EvaluateResponse)
    check ev.kind == LogosNSCapabilityAuthorityEvaluateResponseKind.Map_error
    check ev.arm_Map_error.error.code.kind == CaCode.Not_authorised
    # [S8b-1 interim] The Runtime checks the payload's consumer at the route,
    # whatever the policy kind: the authority's own `not-authorised` is
    # behind it.
    check r.raw("issue_grant", encode(issueReq("c2", "c1")).get).code == ecNotAuthorised
    let audit = r.ask(
      "query_audit", QueryAuditRequest(consumer: address("c1")), QueryAuditResponse
    )
    check audit.arm_Map_records.records.allIt(
      it.kind notin {
        LogosNSCapabilityAuthorityAuditRecordKind.Evaluate_allow,
        LogosNSCapabilityAuthorityAuditRecordKind.Evaluate_deny,
        LogosNSCapabilityAuthorityAuditRecordKind.Evaluate_failure,
      }
    )
    r.release()
    e.finish()
    h.free()

  test "[CAP-0178] [RUN-0856] [RUN-0857] a protected issuance publishes grant_changed through the instance's publish callback, which no ordinary subscription reaches, bound or not":
    var h = newHost()
    h.wire()
    let e = newEngine(h.caConfig)
    discard e.started(caRecord(), "ca")
    let (_, rc) = e.startClient("c1")
    var r = rc.caRoute("ca")
    # The policy here is allow-all and the instance is not bound: the
    # authority's notices are still the Runtime's alone (step 8b).
    var id: LogosSubscriptionId
    for name in [GrantChanged, "logos.capability_authority.policy_changed_event"]:
      check toResult(
        r.vtable.subscribe(addr r, cstring(name), onEvent, addr heard[0], addr id)
      ).code == ecNotAuthorised
    discard
      h.authority.issueProtected(Source, address("c1"), @[callScope(root(M1))]).get
    # The publication was accepted (a failed one would make the authority
    # unavailable), and the route still answers.
    discard
      h.authority.issueProtected(Source, address("c2"), @[callScope(root(M1))]).get
    check r.raw("list_grants", encode(ListGrantsRequest(consumer: address("c1"))).get).code ==
      ecOk
    r.release()
    e.finish()
    h.free()

  test "[CAP-0366] [CAP-0367] [CAP-0368] a watch publishes on its own route only, and an asynchronous cancel ends it":
    var h = newHost()
    h.wire()
    let e = newEngine(h.caConfig)
    discard e.started(caRecord(), "ca")
    let (_, rc1) = e.startClient("c1")
    var r1 = rc1.caRoute("ca")
    discard r1.listen(Observed, 0)
    let (_, rc2) = e.startClient("c2")
    var r2 = rc2.caRoute("ca")
    discard r2.listen(Observed, 1)
    var call = r1.startAsync(
      "watch_changes", encode(WatchChangesRequest(consumer: address("c1"))).get
    )
    check eventually(
      proc(): bool =
        h.authority.watchCount == 1
    )
    let g =
      h.authority.issueProtected(Source, address("c1"), @[callScope(root(M1))]).get
    check eventually(
      proc(): bool =
        heard[0].count.load == 1
    )
    check heard[0].payloadOf == grantChange(g)
    sleep(20)
    check heard[0].count.load == 1
    check heard[1].count.load == 0
    call.vtable.cancel(addr call)
    check eventually(
      proc(): bool =
        done.count.load == 1
    )
    check done.code.load == ord(ecCancelled)
    check eventually(
      proc(): bool =
        h.authority.watchCount == 0
    )
    call.vtable.release(addr call)
    r1.release()
    r2.release()
    e.finish()
    h.free()

  test "[IMPL] stopping the CA ends its watches before it is destroyed":
    var h = newHost()
    h.wire()
    let e = newEngine(h.caConfig)
    discard e.started(caRecord(), "ca")
    let (_, rc) = e.startClient("c1")
    var r = rc.caRoute("ca")
    var call = r.startAsync(
      "watch_changes", encode(WatchChangesRequest(consumer: address("c1"))).get
    )
    check eventually(
      proc(): bool =
        h.authority.watchCount == 1
    )
    check e.stop("ca").tryGet.state == msUnloaded
    check authorityFor(h.caDir).isNone
    check eventually(
      proc(): bool =
        done.count.load == 1
    )
    call.vtable.release(addr call)
    r.release()
    e.finish()
    h.free()

  test "[IMPL] without wiring the CA fails to start and leaves nothing; a second instance on its state assignment is refused (G111)":
    var h = newHost()
    let e = newEngine(h.caConfig)
    discard e.create(caRecord(), "ca").tryGet
    let s = e.start("ca")
    check s.isErr or s.get.state != msReady
    check e.view("ca").tryGet.state != msReady
    check authorityFor(h.caDir).isNone
    h.wire()
    check e.start("ca").tryGet.state == msReady
    check e.create(caRecord(), "ca2").isErr
    e.finish()
    h.free()

  test "[IMPL] only a system registration loads a call surface with the reserved logos names":
    var h = newHost()
    h.wire()
    var cfg = h.caConfig
    var plain = checkStaticRegistration(
      "plain_ca", logosCapabilityAuthorityStaticSymbols()
    ).tryGet
    check not plain.system
    cfg.statics.add plain
    let e = newEngine(cfg)
    var r = caRecord()
    r.binding = "plain_ca"
    discard e.create(r, "ca").tryGet
    discard e.start("ca")
    let v = e.view("ca").tryGet
    check v.state == msError
    # [I89] A typed Loader error is `loader-<code>`; its message stays in the
    # undisclosed reason.
    check v.failure.get.kind == fkLoader and v.failure.get.loader == lecAbiInvalid
    check v.failure.get.internal and "reserved" in v.failure.get.reason
    check authorityFor(h.caDir).isNone
    e.finish()
    h.free()

  test "[IMPL] a restart keeps the grants under the same Runtime id and instance ids":
    var h = newHost()
    h.wire()
    var e = openEngine(h.caConfig(store = true)).tryGet
    discard e.started(caRecord(), "ca")
    let (_, rc) = e.startClient("c1")
    var r = rc.caRoute("ca")
    let g = r.ask("issue_grant", issueReq("c1", "c2"), IssueGrantResponse).grantOf
    r.release()
    e.finish()
    check authorityFor(h.caDir).isNone
    e = openEngine(h.caConfig(store = true)).tryGet
    check e.runtimeInstanceId == Rt
    if e.view("ca").tryGet.state != msReady:
      check e.start("ca").tryGet.state == msReady
    if e.view("c1").tryGet.state != msReady:
      check e.start("c1").tryGet.state == msReady
    let rc2 = cast[ptr LogosRuntimeControlBinding](clients[
      (clientInits.load - 1) mod MaxClients
    ].load)
    var r2 = rc2.caRoute("ca2")
    let listed = r2.ask(
      "list_grants", ListGrantsRequest(consumer: address("c1")), ListGrantsResponse
    )
    check listed.arm_Map_grants.grants.len == 1
    check same(listed.arm_Map_grants.grants[0], g)
    r2.release()
    e.finish()
    h.free()
