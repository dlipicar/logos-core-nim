## Synthetic `call` records of the meter kit contract, shaped as
## `tests/test_evidence.nim`'s, for the call-evidence store's export cases
## (`test_evidence_store`, `test_logosd`; DECISIONS G301).

import std/os
import results
import logos_sdk/[cbor, commitment, hash]
import logos_sdk/iface/accept
import ../../src/logos_core/authority/scopes
import ../../src/logos_core/runtime/evidence

export AuditRecord

let
  meterSet = acceptContractSet(
      readFile(
        currentSourcePath().parentDir.parentDir.parentDir /
          "spec/mirrors/IFC/3.9.1.module.cddl"
      )
    )
    .expect("the meter contract set")
  meterRoot = meterSet.primary.root
  meterModel = meterSet.primary.model

proc rootOf(declaration, diag: string): ValueRoot =
  meterSet.schemaSet.normalize(0, declaration, parseDiag(diag).get).expect("a root")

proc commitmentOf(r: ValueRoot): ValueCommitment =
  ValueCommitment(
    schema_subtree_root: @(r.subtreeRoot), value_root: @(valueRoot(r).expect("a root"))
  )

proc meterCallRecord*(producer, decision: string, timestamp: uint64): AuditRecord =
  ## A success record of one `meter.read` call by `orch` through `route-1`,
  ## both sides retained.
  let readRoot = @(declarationRoot(meterModel, meterModel.find("meter.read").get))
  let scope = toScope(
    ProviderAccessScope(
      contract: SchemaCommitment(schema_root: @meterRoot),
      actions: @[PaAction(kind: PaActionKind.Call)],
      routes: Opt.some(@["route-1"]),
      providers: Opt.some(
        @[ProviderAddress(provider: "meter-1", runtime_instance_id: Opt.some(producer))]
      ),
      access: Opt.some(RouteAccess(methods: Opt.some(@[readRoot]))),
    )
  )
  let request = rootOf("meter.read_request", "{\"channel\": 7}")
  let response =
    rootOf("meter.read_response", "{\"label\": \"t\", \"reading\": {\"value\": 3}}")
  AuditRecord(
    kind: AuditKind.Call_success,
    arm_Call_success: LogosNSCapabilityAuthorityAuditRecordARCallSuccessMap(
      commitments: LogosNSCapabilityAuthorityCallCommitments(
        kind: LogosNSCapabilityAuthorityCallCommitmentsKind.Map_request,
        arm_Map_request: LogosNSCapabilityAuthorityCallCommitmentsARMapRequestMap(
          request: commitmentOf(request), response: Opt.some(commitmentOf(response))
        ),
      ),
      consumer: Address(runtime_instance_id: producer, module_instance_id: "orch"),
      decision_id: decision,
      scopes: (scope,),
      timestamp: timestamp,
    ),
  )

proc meterCallRecordBytes*(producer, decision: string, timestamp: uint64): seq[byte] =
  ## The record as the Runtime retains it: deterministic CBOR.
  encode(meterCallRecord(producer, decision, timestamp)).expect("an encoding")
