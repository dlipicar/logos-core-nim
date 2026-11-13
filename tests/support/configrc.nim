## Runtime Control configuration requests for a test that includes the route
## fixture and imports `support/tunerconfig` (DECISIONS I87): the target
## address, the reads and `update_configuration`'s stage and discard.

proc target(e: Engine, id: string): LogosNSRuntimeModuleInstanceAddress =
  LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: e.runtimeInstanceId(), module_instance_id: id
  )

proc summaryOf(
    rc: ptr LogosRuntimeControlBinding, t: LogosNSRuntimeModuleInstanceAddress
): RcResult =
  rcCall(
    rc,
    "get_configuration_summary",
    encode(LogosNSRuntimeControlGetConfigurationSummaryRequest(target: t)).tryGet,
  )

proc summary(
    rc: ptr LogosRuntimeControlBinding, t: LogosNSRuntimeModuleInstanceAddress
): LogosNSModuleConfigurationConfigurationStateSummary =
  let r = rc.summaryOf(t)
  doAssert r.code == ecOk, r.message
  LogosNSRuntimeControlGetConfigurationSummaryResponse.decode(r.response).tryGet.state

proc schemaOf(
    rc: ptr LogosRuntimeControlBinding, t: LogosNSRuntimeModuleInstanceAddress
): RcResult =
  rcCall(
    rc,
    "get_configuration_schema",
    encode(LogosNSRuntimeControlGetConfigurationSchemaRequest(target: t)).tryGet,
  )

proc stateOf(
    rc: ptr LogosRuntimeControlBinding, t: LogosNSRuntimeModuleInstanceAddress
): RcResult =
  rcCall(
    rc,
    "get_configuration",
    encode(LogosNSRuntimeControlGetConfigurationRequest(target: t)).tryGet,
  )

proc state(
    rc: ptr LogosRuntimeControlBinding, t: LogosNSRuntimeModuleInstanceAddress
): LogosNSModuleConfigurationConfigurationState =
  let r = rc.stateOf(t)
  doAssert r.code == ecOk, r.message
  LogosNSRuntimeControlGetConfigurationResponse.decode(r.response).tryGet.state

proc stage(
    rc: ptr LogosRuntimeControlBinding,
    t: LogosNSRuntimeModuleInstanceAddress,
    revision: uint64,
    value: seq[byte],
    commitment = tunerCommitment(),
): RcResult =
  rcCall(
    rc,
    "update_configuration",
    encode(
      LogosNSRuntimeControlUpdateConfigurationRequest(
        kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Stage,
        arm_Stage: LogosNSRuntimeControlUpdateConfigurationRequestARStageMap(
          target: t,
          expected_state_revision: revision,
          expected_schema_commitment: commitment,
          value: value,
        ),
      )
    ).tryGet,
  )

proc discardStaged(
    rc: ptr LogosRuntimeControlBinding,
    t: LogosNSRuntimeModuleInstanceAddress,
    revision: uint64,
): RcResult =
  rcCall(
    rc,
    "update_configuration",
    encode(
      LogosNSRuntimeControlUpdateConfigurationRequest(
        kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Discard,
        arm_Discard: LogosNSRuntimeControlUpdateConfigurationRequestARDiscardMap(
          target: t,
          expected_state_revision: revision,
          expected_schema_commitment: tunerCommitment(),
        ),
      )
    ).tryGet,
  )

proc updated(r: RcResult): LogosNSRuntimeControlUpdateConfigurationResponse =
  doAssert r.code == ecOk, r.message
  LogosNSRuntimeControlUpdateConfigurationResponse.decode(r.response).tryGet

func provenanceOf(p: LogosNSModuleConfigurationProvenance): Provenance =
  case p.kind
  of LogosNSModuleConfigurationProvenanceKind.Package_default:
    pvPackageDefault
  of LogosNSModuleConfigurationProvenanceKind.Protected_provisioning:
    pvProtectedProvisioning
  of LogosNSModuleConfigurationProvenanceKind.Runtime_control_update:
    pvRuntimeControlUpdate
