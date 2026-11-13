## The Host Embedding API under 8a's Capability Authority (step 8b-2; DECISIONS
## I85, plan case H4): a `capability-authority` configuration started through
## `logos_runtime_start`, with the library's own authority binding wired at
## its state directory (C9) and deciding every module operation. The
## orchestration instance is routefixture's client module, the provider the
## meter kit module; the host issues and revokes grants through 8a's protected
## path (`issueProtected`, `revokeProtected`). Case H5 (step 8b-3): call records
## from a policy allow that retains commitments, read and exported as call
## evidence through the host (plan case E7).

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/[engine, host]
import ../src/logos_core/runtime/host_config_types except
  LcnAuthorityPolicy, LcnAuthorityPolicyAuditMap
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime]
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
import ../src/logos_core/runtime/evidence
from ../src/logos_core/crypto/slhdsa import generateKeyPair
from std/posix import Mode, chmod

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "host_authority" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# The deployment -----------------------------------------------------------------------

const
  RtId = "rt-h4"
  Orch = "orch"
  Ca = "ca"
  Meter = "meter-1"
  CaAssignment = "ca-state"
  HostSource = "h4.host"

proc module(instance, module, binding: string): LcnAppModule =
  LcnAppModule(
    instance: instance,
    module: module,
    implementation: LcnAppImplementation(
      kind: LcnAppImplementationKind.Direct_static,
      arm_Direct_static: LcnAppImplementationARDirectStaticMap(binding: binding),
    ),
  )

proc h4Policy(): host_config_types.LcnAuthorityPolicy =
  ## The orchestrator may use Runtime Control; starting a module and reaching
  ## a provider take a grant.
  let bytes =
    policyBytes(@[allowRule(subject(modules = @["client_module"]), @[rcPattern()])])
  host_config_types.LcnAuthorityPolicy.fromCbor(decodeCbor(bytes).tryGet).tryGet

proc h4Config(dir: string): LcnAppConfig =
  var ca = module(Ca, "logos_capability_authority", "logos_capability_authority")
  ca.state_assignment = Opt.some(CaAssignment)
  var meter = module(Meter, "meter_module", "meter")
  meter.primary_contract = Opt.some(SchemaCommitment(schema_root: @meterRoot))
  LcnAppConfig(
    runtime: LcnAppRuntime(
      work_dir: dir / "w",
      state_root: Opt.some(dir / "state"),
      store_dir: Opt.some(dir / "store"),
      runtime_instance_id: Opt.some(RtId),
    ),
    policy: LcnAppPolicy(
      kind: LcnAppPolicyKind.Capability_authority,
      # A generous evaluation deadline, so a loaded sanitizer host does not
      # fail closed.
      arm_Capability_authority: LcnAppPolicyARCapabilityAuthorityMap(
        authority: Ca, policy: h4Policy(), evaluation_deadline_ms: Opt.some(60_000'u32)
      ),
    ),
    orchestration: Orch,
    modules: @[module(Orch, "client_module", "client"), ca, meter],
  )

proc execScopes(): seq[Scope] =
  ## The orchestrator may start the meter.
  @[meScope("meter_module", Opt.some(Meter), runtimeId = RtId)]

proc accessScopes(): seq[Scope] =
  ## The orchestrator may reach the meter's contract.
  let contract = SchemaCommitment(schema_root: @meterRoot)
  result = @[
    pa(@[PaActionKind.Establish_route], contract),
    pa(@[PaActionKind.Renew_route], contract),
    pa(@[PaActionKind.Call], contract),
  ]
  canonicalOrder(result)

# Host calls ---------------------------------------------------------------------------

proc ec(r: LogosResult): ErrorCode =
  errorCode(int64(r.code)).get

proc create(c: LcnAppConfig): ptr LogosRuntimeHandle =
  let bytes = c.encode.get
  var cfg = LogosRuntimeConfig(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeConfig)),
    configurationFormat: AppConfigFormat,
    configuration: cast[ptr UncheckedArray[uint8]](unsafeAddr bytes[0]),
    configurationLen: csize_t(bytes.len),
  )
  check runtimeCreate(addr cfg, addr result).ec == ecOk

proc register(
    rt: ptr LogosRuntimeHandle, id: string, table: openArray[(string, pointer)]
): ErrorCode =
  var names: seq[string]
  for (n, _) in table:
    names.add(n)
  var symbols = newSeq[LogosRuntimeNativeSymbol](table.len)
  for i in 0 ..< table.len:
    symbols[i] = LogosRuntimeNativeSymbol(
      name: cstring(names[i]), address: cast[LogosRuntimeSymbolAddress](table[i][1])
    )
  var b = LogosRuntimeNativeBinding(
    abiVersion: RuntimeHostAbiVersion,
    structSize: csize_t(sizeof(LogosRuntimeNativeBinding)),
    binding: cstring(id),
    symbols: cast[ptr UncheckedArray[LogosRuntimeNativeSymbol]](addr symbols[0]),
    symbolCount: csize_t(symbols.len),
  )
  runtimeRegisterBinding(rt, addr b).ec

proc shutDown(rt: ptr LogosRuntimeHandle) =
  check runtimeRequestShutdown(rt).ec == ecOk
  check runtimeWaitForShutdown(rt).ec == ecOk
  check runtimeDestroy(rt).ec == ecOk

proc latestClient(): ptr LogosRuntimeControlBinding =
  cast[ptr LogosRuntimeControlBinding](clients[(clientInits.load - 1) mod MaxClients].load)

proc reaches(e: Engine, instance: string, state: ModuleState): bool =
  waitUntil(
    proc(): bool =
      e.view(instance).tryGet.state == state
  )

proc routeState(e: Engine, route: string): LogosNSRuntimeControlRouteRecord =
  e.routes().filterIt(it.route == route)[0]

proc recoverReq(e: Engine, instance: string): seq[byte] =
  encode(
    LogosNSRuntimeControlRecoverModuleRequest(
      module: "meter_module",
      instance: instance,
      expected_execution_revision: e.view(instance).tryGet.execution.revision,
    )
  ).tryGet

# H4 -------------------------------------------------------------------------------------

suite "run.host-api: under 8a's Capability Authority (I85; C9)":
  test "[RUN-0185] [RUN-1066] [BCP-0073] start binds the library's authority; grants let orchestration start a module and reach it over a route; revoking them revokes the route and stops the module; a new grant lets recover_module start it again":
    let dir = work / "h4"
    let rt = create(h4Config(dir))
    check rt.register("client", clientTable()) == ecOk
    check rt.register("meter", meterModuleStaticSymbols()) == ecOk
    check runtimeStart(rt).ec == ecOk
    let e = engineOf(rt)
    let orch = latestClient()
    # [RUNTIME l.1635-1650] Bootstrap starts the orchestration instance, which
    # starts the authority under the derived rules; then it is bound.
    check not e.authorityBound()[0]
    check orch.lifecycle("start_module", "logos_capability_authority", Opt.some(Ca)).code ==
      ecOk
    check e.view(Ca).tryGet.state == msReady
    check e.authorityBound()[0]
    # No grant yet: the policy lets the orchestrator ask, not start.
    check orch.lifecycle("start_module", "meter_module", Opt.some(Meter)).code ==
      ecNotAuthorised
    check e.view(Meter).tryGet.state == msUnloaded
    let a = authorityFor(dir / "state" / CaAssignment).get
    let exec = a.issueProtected(HostSource, address(Orch, RtId), execScopes()).tryGet
    check orch.lifecycle("start_module", "meter_module", Opt.some(Meter)).code == ecOk
    check e.reaches(Meter, msReady)
    check orch.establish("h4-0").code == ecNotAuthorised
    let reach = a.issueProtected(HostSource, address(Orch, RtId), accessScopes()).tryGet
    let r = orch.establish("h4-1")
    check r.code == ecOk
    let route = r.routesOf.routes[0].route
    var h = orch.handle(route)
    check h.read(1).isOk
    # [CA l.869-914] A revocation reaches the Runtime as `grant_changed`: the
    # route it supported is re-authorized and denied.
    check a.revokeProtected(HostSource, reach.grant_id).isOk
    check waitUntil(
      proc(): bool =
        e.routeState(route).state.kind == LogosNSRuntimeControlRouteStateKind.Revoked
    )
    let ended = e.routeState(route)
    checkpoint $ended
    check ended.failure.isSome and ended.failure.get.code == "authority-denied"
    check h.read(1).isErr
    h.release()
    check e.view(Meter).tryGet.state == msReady
    # [CA l.884-891] The execution it supported ends.
    check a.revokeProtected(HostSource, exec.grant_id).isOk
    check e.reaches(Meter, msUnloaded)
    let stopped = e.view(Meter).tryGet
    check stopped.failure.isSome
    check stopped.failure.get.kind == fkAuthorityRevoked
    check stopped.execution.intent == inRequested
    # A new grant, and orchestration recovers the module.
    discard a.issueProtected(HostSource, address(Orch, RtId), execScopes()).tryGet
    check rcCall(orch, "recover_module", e.recoverReq(Meter)).code == ecOk
    check e.reaches(Meter, msReady)
    check e.view(Meter).tryGet.failure.isNone
    rt.shutDown()
    # [C9] Unwired at destroy: the directory can be wired again.
    let f = newSharedFacts(RtId)
    check wireAuthority(
      dir / "state" / CaAssignment, AuthorityWiring(runtimeId: RtId, facts: f)
    ).isOk
    unwireAuthority(dir / "state" / CaAssignment)
    freeSharedFacts(f)

# H5 -------------------------------------------------------------------------------------

proc retainBoth(): Opt[policy_types.LcnApCommitment] =
  Opt.some(
    policy_types.LcnApCommitment(
      request: Opt.some("retain-root"), response: Opt.some("retain-root")
    )
  )

proc h5Config(dir, keyFile: string, kid: seq[byte]): LcnAppConfig =
  ## The orchestrator may start the meter and reach it; its calls to the
  ## meter retain both commitments. Two records are kept.
  let contract = SchemaCommitment(schema_root: @meterRoot)
  let orch = subject(modules = @["client_module"])
  let bytes = policyBytes(
    @[
      allowRule(
        orch,
        @[
          rcPattern(),
          mePattern(
            subject(instances = @[Meter]),
            @[policy_types.LcnApModuleExecutionActionsLIChoiceKind.Start],
          ),
          paPattern(
            @[
              policy_types.LcnApActionKind.Establish_route,
              policy_types.LcnApActionKind.Renew_route,
            ],
            exact = contract,
          ),
        ],
      ),
      allowRule(
        orch,
        @[paPattern(@[policy_types.LcnApActionKind.Call], exact = contract)],
        retainBoth(),
      ),
    ]
  )
  result = h4Config(dir)
  result.policy.arm_Capability_authority.policy =
    host_config_types.LcnAuthorityPolicy.fromCbor(decodeCbor(bytes).tryGet).tryGet
  result.call_audit = Opt.some(
    LcnAppCallAudit(
      call_records: Opt.some(2'u32),
      evidence: Opt.some(LcnAppEvidenceKey(kid: kid, secret_key_file: keyFile)),
    )
  )

suite "run.host-api: call records and call evidence (I85; CA §9, §9.1)":
  test "[RUN-0334] [CAP-0205] [CAP-0415] [CAP-0416] [CAP-0417] [CAP-0418] a policy allow that retains commitments leaves call records the host reads, newest kept; the host exports one as call evidence under its configured key with this Runtime as producer, and a record no longer kept is not exported":
    let dir = work / "h5"
    createDir(dir)
    let keyFile = dir / "evidence.key"
    let kid = @[0x68'u8, 0x35]
    var (key, pub) = generateKeyPair().tryGet
    removeFile(keyFile)
    writeFile(keyFile, cast[string](@key))
    key.clear()
    check chmod(cstring(keyFile), Mode(0o600)) == 0
    let rt = create(h5Config(dir, keyFile, kid))
    check rt.register("client", clientTable()) == ecOk
    check rt.register("meter", meterModuleStaticSymbols()) == ecOk
    check runtimeStart(rt).ec == ecOk
    let e = engineOf(rt)
    let orch = latestClient()
    check orch.lifecycle("start_module", "logos_capability_authority", Opt.some(Ca)).code ==
      ecOk
    check e.authorityBound()[0]
    check orch.lifecycle("start_module", "meter_module", Opt.some(Meter)).code == ecOk
    check e.reaches(Meter, msReady)
    let r = orch.establish("h5")
    check r.code == ecOk
    var h = orch.handle(r.routesOf.routes[0].route)
    for channel in 1'u32 .. 3:
      check h.read(channel).isOk
    h.release()
    # Only calls retain; the newest two of three are kept.
    let kept = rt.auditRecords
    check kept.mapIt(it.index) == @[1'u64, 2]
    check rt.exportCallEvidence(0).isErr
    let container = rt.exportCallEvidence(2)
    check container.isOk
    var ctx = newEvidenceContext()
    check ctx.accept(kid, RtId, pub).isOk
    let v = verifyEvidence(container.get, ctx)
    check v.isOk
    check v.get.producer == RtId
    check encode(v.get.record).tryGet == kept[1].bytes
    check v.get.record.kind == AuditKind.Call_success
    check v.get.record.arm_Call_success.consumer == address(Orch, RtId)
    check v.get.proofs.isNone
    rt.shutDown()
    removeFile(keyFile)
