## The two arms of the Runtime Control responses that carry a typed error
## (RUNTIME §9.3.1 l.1818-1822, §9.3.2; re-pin P4a; DECISIONS I108) [IMPL].
##
## Eight responses are a choice of a result and `{ error }`: create_module,
## start_module, stop_module, recover_module, retire_module,
## update_permission_settings, update_configuration and apply_configuration.
## The generator names each arm by its fields (`rc_types.nim`), so the names
## differ per response. For each response type `T` this gives:
##
## - `T.accepted(v)`: the response whose result arm is `v`;
## - `T.refused(e)`: the response whose error arm holds `e`;
## - `r.accepted`: the result arm, none for the error arm;
## - `r.refusal`: the error, none for the result arm.
##
## A typed error is a successful response: a reader that takes the call's
## status alone for acceptance is wrong, so every reader goes through these.

{.push raises: [].}

import results
import ./rc_types

export results, rc_types

func rcError*(
    code: LogosNSRuntimeControlErrorCodeKind, current = Opt.none(uint64)
): LogosNSRuntimeControlError =
  LogosNSRuntimeControlError(
    code: LogosNSRuntimeControlErrorCode(kind: code), current_revision: current
  )

func codeText*(e: LogosNSRuntimeControlError): string =
  ## The code as the schema spells it (RUNTIME §9.3.2 `error_code`).
  case e.code.kind
  of LogosNSRuntimeControlErrorCodeKind.Stale_revision:
    "stale-revision"
  of LogosNSRuntimeControlErrorCodeKind.Configuration_rejected:
    "configuration-rejected"
  of LogosNSRuntimeControlErrorCodeKind.Declaration_unavailable:
    "declaration-unavailable"

func `$`*(e: LogosNSRuntimeControlError): string =
  ## The code, and the current revision when present.
  result = e.codeText
  if e.current_revision.isSome:
    result.add(" (current revision " & $e.current_revision.get & ")")

template arms(T, A, E: typedesc, ok, okArm, bad, badArm: untyped) =
  func accepted*(_: typedesc[T], v: A): T =
    T(kind: ok, okArm: v)

  func refused*(_: typedesc[T], e: LogosNSRuntimeControlError): T =
    T(kind: bad, badArm: E(error: e))

  func accepted*(r: T): Opt[A] =
    if r.kind == ok:
      Opt.some(r.okArm)
    else:
      Opt.none(A)

  func refusal*(r: T): Opt[LogosNSRuntimeControlError] =
    if r.kind == bad:
      Opt.some(r.badArm.error)
    else:
      Opt.none(LogosNSRuntimeControlError)

arms(
  LogosNSRuntimeControlCreateModuleResponse,
  LogosNSRuntimeControlCreateModuleResponseARMapInstanceModuleMap,
  LogosNSRuntimeControlCreateModuleResponseARMapErrorMap,
  LogosNSRuntimeControlCreateModuleResponseKind.Map_instance_module,
  arm_Map_instance_module, LogosNSRuntimeControlCreateModuleResponseKind.Map_error,
  arm_Map_error,
)

arms(
  LogosNSRuntimeControlStartModuleResponse,
  LogosNSRuntimeControlStartModuleResponseARMapModuleStateMap,
  LogosNSRuntimeControlStartModuleResponseARMapErrorMap,
  LogosNSRuntimeControlStartModuleResponseKind.Map_module_state, arm_Map_module_state,
  LogosNSRuntimeControlStartModuleResponseKind.Map_error, arm_Map_error,
)

arms(
  LogosNSRuntimeControlStopModuleResponse,
  LogosNSRuntimeControlStopModuleResponseARMapModuleStateMap,
  LogosNSRuntimeControlStopModuleResponseARMapErrorMap,
  LogosNSRuntimeControlStopModuleResponseKind.Map_module_state, arm_Map_module_state,
  LogosNSRuntimeControlStopModuleResponseKind.Map_error, arm_Map_error,
)

arms(
  LogosNSRuntimeControlRecoverModuleResponse,
  LogosNSRuntimeControlRecoverModuleResponseARMapInstanceModuleStateMap,
  LogosNSRuntimeControlRecoverModuleResponseARMapErrorMap,
  LogosNSRuntimeControlRecoverModuleResponseKind.Map_instance_module_state,
  arm_Map_instance_module_state,
  LogosNSRuntimeControlRecoverModuleResponseKind.Map_error, arm_Map_error,
)

arms(
  LogosNSRuntimeControlRetireModuleResponse,
  LogosNSRuntimeControlRetireModuleResponseARMapMap,
  LogosNSRuntimeControlRetireModuleResponseARMapErrorMap,
  LogosNSRuntimeControlRetireModuleResponseKind.Map, arm_Map,
  LogosNSRuntimeControlRetireModuleResponseKind.Map_error, arm_Map_error,
)

arms(
  LogosNSRuntimeControlUpdatePermissionSettingsResponse,
  LogosNSRuntimeControlUpdatePermissionSettingsResponseARMapStateTargetMap,
  LogosNSRuntimeControlUpdatePermissionSettingsResponseARMapErrorMap,
  LogosNSRuntimeControlUpdatePermissionSettingsResponseKind.Map_state_target,
  arm_Map_state_target,
  LogosNSRuntimeControlUpdatePermissionSettingsResponseKind.Map_error, arm_Map_error,
)

arms(
  LogosNSRuntimeControlUpdateConfigurationResponse,
  LogosNSRuntimeControlUpdateConfigurationResponseARMapStateRevisionTargetMap,
  LogosNSRuntimeControlUpdateConfigurationResponseARMapErrorMap,
  LogosNSRuntimeControlUpdateConfigurationResponseKind.Map_state_revision_target,
  arm_Map_state_revision_target,
  LogosNSRuntimeControlUpdateConfigurationResponseKind.Map_error, arm_Map_error,
)

arms(
  LogosNSRuntimeControlApplyConfigurationResponse,
  LogosNSRuntimeControlApplyConfigurationResponseARMapAppliedValueRevisionStateRevisionTargetMap,
  LogosNSRuntimeControlApplyConfigurationResponseARMapErrorMap,
  LogosNSRuntimeControlApplyConfigurationResponseKind.Map_applied_value_revision_state_revision_target,
  arm_Map_applied_value_revision_state_revision_target,
  LogosNSRuntimeControlApplyConfigurationResponseKind.Map_error, arm_Map_error,
)
