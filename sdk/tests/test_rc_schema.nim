## The Runtime Types and Runtime Control contract (RUNTIME §9.2, §9.3), rule by
## rule (DECISIONS I88, W2): values built from the accepted model validate and
## round-trip byte for byte through `kit/rc_types.nim`; values outside a
## bound are refused (`support/schemasuite`). One test per rule, named by its
## requirement id. Then the enrollment schema (§9.3.7), which is not part of
## the contract, and the App B examples (re-pin P4a; DECISIONS I108).

import std/[sequtils, strutils]
import unittest2
import logos_sdk/cddl
import logos_sdk/kit/[rc_arms, rc_types]
import logos_sdk/testing/[schemasuite, specdata]

const Rules = [
  "logos.runtime.module_name", "logos.runtime.runtime_instance_id",
  "logos.runtime.module_instance_id", "logos.runtime.module_provider_id",
  "logos.runtime.route_id", "logos.runtime.module_state_assignment_id",
  "logos.runtime.module_instance_address", "logos.runtime.module_provider_address",
  "logos.runtime_control.reason", "logos.runtime_control.address_profile",
  "logos.runtime_control.decision_id", "logos.runtime_control.failure_code",
  "logos.runtime_control.host_name", "logos.runtime_control.port",
  "logos.runtime_control.path", "logos.runtime_control.server_name",
  "logos.runtime_control.alpn", "logos.runtime_control.state",
  "logos.runtime_control.mode", "logos.runtime_control.route_state",
  "logos.runtime_control.unix_stream_runtime_address",
  "logos.runtime_control.tls_tcp_runtime_address",
  "logos.runtime_control.quic_runtime_address", "logos.runtime_control.runtime_address",
  "logos.runtime_control.runtime_endpoint",
  "logos.runtime_control.remote_listener_address",
  "logos.runtime_control.remote_listener_record",
  "logos.runtime_control.provider_export_record",
  "logos.runtime_control.remote_provider_target",
  "logos.runtime_control.execution_state", "logos.runtime_control.module_record",
  "logos.runtime_control.invocation_descriptor", "logos.runtime_control.route_failure",
  "logos.runtime_control.error_code", "logos.runtime_control.error",
  "logos.runtime_control.route_access",
  "logos.runtime_control.provider_requirement_cardinality",
  "logos.runtime_control.route_record", "logos.runtime_control.establish_route_request",
  "logos.runtime_control.route_continuation",
  "logos.runtime_control.establish_route_response",
  "logos.runtime_control.renew_route_request",
  "logos.runtime_control.renew_route_response",
  "logos.runtime_control.describe_provider_request",
  "logos.runtime_control.describe_provider_response",
  "logos.runtime_control.list_modules_request",
  "logos.runtime_control.list_modules_response",
  "logos.runtime_control.list_routes_request",
  "logos.runtime_control.list_routes_response",
  "logos.runtime_control.list_remote_listeners_request",
  "logos.runtime_control.list_remote_listeners_response",
  "logos.runtime_control.set_remote_listener_request",
  "logos.runtime_control.set_remote_listener_response",
  "logos.runtime_control.list_provider_exports_request",
  "logos.runtime_control.list_provider_exports_response",
  "logos.runtime_control.set_provider_export_request",
  "logos.runtime_control.set_provider_export_response",
  "logos.runtime_control.close_route_request",
  "logos.runtime_control.close_route_response",
  "logos.runtime_control.create_module_request",
  "logos.runtime_control.create_module_response",
  "logos.runtime_control.start_module_request",
  "logos.runtime_control.start_module_response",
  "logos.runtime_control.stop_module_request",
  "logos.runtime_control.stop_module_response",
  "logos.runtime_control.recover_module_request",
  "logos.runtime_control.recover_module_response",
  "logos.runtime_control.report_failure_request",
  "logos.runtime_control.report_failure_response",
  "logos.runtime_control.shutdown_runtime_request",
  "logos.runtime_control.shutdown_runtime_response",
  "logos.runtime_control.execution_selection",
  "logos.runtime_control.get_execution_summary_request",
  "logos.runtime_control.get_execution_summary_response",
  "logos.runtime_control.get_readiness_request",
  "logos.runtime_control.get_readiness_response",
  "logos.runtime_control.permission_setting",
  "logos.runtime_control.permission_settings_state",
  "logos.runtime_control.get_permission_settings_request",
  "logos.runtime_control.get_permission_settings_response",
  "logos.runtime_control.update_permission_settings_request",
  "logos.runtime_control.update_permission_settings_response",
  "logos.runtime_control.permission_settings_changed_event",
  "logos.runtime_control.get_configuration_schema_request",
  "logos.runtime_control.get_configuration_schema_response",
  "logos.runtime_control.get_configuration_summary_request",
  "logos.runtime_control.get_configuration_summary_response",
  "logos.runtime_control.get_configuration_request",
  "logos.runtime_control.get_configuration_response",
  "logos.runtime_control.update_configuration_request",
  "logos.runtime_control.update_configuration_response",
  "logos.runtime_control.apply_configuration_request",
  "logos.runtime_control.apply_configuration_response",
  "logos.runtime_control.configuration_state_changed_event",
  "logos.runtime_control.execution_state_changed_event",
  "logos.runtime_control.module_state_changed_event",
  "logos.runtime_control.route_state_changed_event", "logos.runtime_control.cursor",
  "logos.runtime_control.inventory_collection",
  "logos.runtime_control.get_self_request", "logos.runtime_control.get_self_response",
  "logos.runtime_control.retire_module_request",
  "logos.runtime_control.retire_module_response",
  "logos.runtime_control.get_execution_permissions_request",
  "logos.runtime_control.get_execution_permissions_response",
  "logos.runtime_control.inventory_changed_event",
]

let
  model = ruleModel(rcDocuments())
  codec = codecTable("LogosNS", Rules)

template holds(name: string) =
  let problems = model.checkRule(name, codec)
  for p in problems:
    checkpoint name & ": " & p
  check problems.len == 0

template armsHold(T: typedesc, name: string) =
  ## [SPEC RUNTIME l.1818-1822] A response that is a choice of its result
  ## and `{ error }`: the rule holds, and its error arm, with and without
  ## `current_revision`, validates and decodes to the same error.
  holds name
  for current in [Opt.some(3'u64), Opt.none(uint64)]:
    let e = rcError(LogosNSRuntimeControlErrorCodeKind.Stale_revision, current)
    let bytes = encode(T.refused(e)).tryGet
    check model.g.check(name, decodeCbor(bytes).tryGet).isOk
    let back = T.decode(bytes).tryGet
    check back.accepted.isNone
    check back.refusal.get.code.kind == e.code.kind
    check back.refusal.get.current_revision == current

proc appB(name: string): CborValue =
  ## An App B example, mirrored from the spec text (`spec/mirrors.toml`), as a
  ## CBOR value. The examples write member names bare; quoting them is all
  ## that separates their notation from diagnostic notation.
  var text = ""
  for line in mirror("RNT/" & name).splitLines:
    let body = line.strip(trailing = false)
    let colon = body.find(':')
    if colon > 0 and body[0 ..< colon].allCharsInSet({'a' .. 'z', '_'}):
      text.add(line[0 ..< line.len - body.len] & '"' & body[0 ..< colon] & '"')
      text.add(body[colon .. ^1])
    else:
      text.add(line)
    text.add('\n')
  parseDiag(text).tryGet

suite "run.schema: Runtime Types and Runtime Control (RUNTIME §9.2, §9.3)":
  test "every rule of the contract has its test here":
    for r in model.names:
      checkpoint r
      check r in Rules
    # The codec half is exercised: every map or choice rule declared by
    # this contract has a generated type that round-trips.
    var objects = 0
    for r in Rules:
      if r in model.names and model.composite(r):
        checkpoint r
        check codec(r, model.samples(r)[0]).isSome
        inc objects
    check objects > 0

  test "[RUN-0374] the contract is the logos_runtime_control module (§9.3 l.1936)":
    check model.moduleName == "logos_runtime_control"

  test "[RUN-0365] logos.runtime.module_name (§9.2 l.1859)":
    holds "logos.runtime.module_name"

  test "[RUN-0366] logos.runtime.runtime_instance_id (§9.2 l.1860)":
    holds "logos.runtime.runtime_instance_id"

  test "[RUN-0367] logos.runtime.module_instance_id (§9.2 l.1861)":
    holds "logos.runtime.module_instance_id"

  test "[RUN-0368] logos.runtime.module_provider_id (§9.2 l.1862)":
    holds "logos.runtime.module_provider_id"

  test "[RUN-0369] logos.runtime.route_id (§9.2 l.1863)":
    holds "logos.runtime.route_id"

  test "[RUN-0370] logos.runtime.module_state_assignment_id (§9.2 l.1864)":
    holds "logos.runtime.module_state_assignment_id"

  test "[RUN-0371] logos.runtime.module_instance_address (§9.2 l.1866)":
    holds "logos.runtime.module_instance_address"

  test "[RUN-0372] logos.runtime.module_provider_address (§9.2 l.1871)":
    holds "logos.runtime.module_provider_address"

  test "[RUN-0375] logos.runtime_control.reason (§9.3 l.1942)":
    holds "logos.runtime_control.reason"

  test "[RUN-0376] logos.runtime_control.address_profile (§9.3 l.1943)":
    holds "logos.runtime_control.address_profile"

  test "[RUN-0377] logos.runtime_control.decision_id (§9.3 l.1944)":
    holds "logos.runtime_control.decision_id"

  test "[RUN-0378] logos.runtime_control.failure_code (§9.3 l.1945)":
    holds "logos.runtime_control.failure_code"

  test "[RUN-0379] logos.runtime_control.host_name (§9.3 l.1946)":
    holds "logos.runtime_control.host_name"

  test "[RUN-0380] logos.runtime_control.port (§9.3 l.1947)":
    holds "logos.runtime_control.port"

  test "[RUN-0381] logos.runtime_control.path (§9.3 l.1948)":
    holds "logos.runtime_control.path"

  test "[RUN-0382] logos.runtime_control.server_name (§9.3 l.1949)":
    holds "logos.runtime_control.server_name"

  test "[RUN-0383] logos.runtime_control.alpn (§9.3 l.1950)":
    holds "logos.runtime_control.alpn"

  test "[RUN-0384] logos.runtime_control.state (§9.3 l.1952)":
    holds "logos.runtime_control.state"

  test "[RUN-0385] logos.runtime_control.mode (§9.3 l.1959)":
    holds "logos.runtime_control.mode"

  test "[RUN-1127] logos.runtime_control.route_state, without `draining` (§9.3.2 l.1886)":
    holds "logos.runtime_control.route_state"
    for state in ["establishing", "ready", "revoked", "failed", "closed"]:
      check model.g.check("logos.runtime_control.route_state", cbor(state)).isOk
    check model.g.check("logos.runtime_control.route_state", cbor("draining")).isErr

  test "[RUN-0387] logos.runtime_control.unix_stream_runtime_address (§9.3 l.1972)":
    holds "logos.runtime_control.unix_stream_runtime_address"

  test "[RUN-0388] logos.runtime_control.tls_tcp_runtime_address (§9.3 l.1978)":
    holds "logos.runtime_control.tls_tcp_runtime_address"

  test "[RUN-0389] logos.runtime_control.quic_runtime_address (§9.3 l.1986)":
    holds "logos.runtime_control.quic_runtime_address"

  test "[RUN-0390] logos.runtime_control.runtime_address (§9.3 l.1995)":
    holds "logos.runtime_control.runtime_address"

  test "[RUN-0391] logos.runtime_control.runtime_endpoint (§9.3 l.2000)":
    holds "logos.runtime_control.runtime_endpoint"

  test "[RUN-0396] logos.runtime_control.remote_listener_address (§9.3 l.2030)":
    holds "logos.runtime_control.remote_listener_address"

  test "[RUN-0397] logos.runtime_control.remote_listener_record (§9.3 l.2034)":
    holds "logos.runtime_control.remote_listener_record"

  test "[RUN-0398] logos.runtime_control.provider_export_record (§9.3 l.2040)":
    holds "logos.runtime_control.provider_export_record"

  test "[RUN-0399] logos.runtime_control.remote_provider_target (§9.3 l.2046)":
    holds "logos.runtime_control.remote_provider_target"

  test "[RUN-0400] logos.runtime_control.execution_state (§9.3 l.2052)":
    holds "logos.runtime_control.execution_state"

  test "[RUN-1128] logos.runtime_control.module_record, with `? extends` (§9.3.2 l.1954)":
    holds "logos.runtime_control.module_record"
    check LogosNSRuntimeControlModuleRecord().extends.isNone

  test "[RUN-0402] logos.runtime_control.invocation_descriptor (§9.3 l.2073)":
    holds "logos.runtime_control.invocation_descriptor"

  test "[RUN-0403] logos.runtime_control.route_failure (§9.3 l.2088)":
    holds "logos.runtime_control.route_failure"

  test "[RUN-1129] logos.runtime_control.error_code (§9.3.2 l.1990)":
    holds "logos.runtime_control.error_code"
    for code in ["stale-revision", "configuration-rejected", "declaration-unavailable"]:
      check model.g.check("logos.runtime_control.error_code", cbor(code)).isOk
    check model.g.check("logos.runtime_control.error_code", cbor("revision-mismatch")).isErr

  test "[RUN-1130] logos.runtime_control.error, with and without current_revision (§9.3.2 l.1995)":
    holds "logos.runtime_control.error"
    for e in [
      rcError(LogosNSRuntimeControlErrorCodeKind.Stale_revision, Opt.some(9'u64)),
      rcError(LogosNSRuntimeControlErrorCodeKind.Configuration_rejected),
      rcError(LogosNSRuntimeControlErrorCodeKind.Declaration_unavailable),
    ]:
      let bytes = encode(e).tryGet
      check model.g.check("logos.runtime_control.error", decodeCbor(bytes).tryGet).isOk
      let back = LogosNSRuntimeControlError.decode(bytes).tryGet
      check back.code.kind == e.code.kind
      check back.current_revision == e.current_revision
      check back.codeText == e.codeText

  test "[RUN-0404] logos.runtime_control.route_access (§9.3 l.2093)":
    holds "logos.runtime_control.route_access"

  test "[RUN-0405] logos.runtime_control.provider_requirement_cardinality (§9.3 l.2099)":
    holds "logos.runtime_control.provider_requirement_cardinality"

  test "[RUN-0406] logos.runtime_control.route_record (§9.3 l.2103)":
    holds "logos.runtime_control.route_record"

  test "[RUN-0407] logos.runtime_control.establish_route_request (§9.3 l.2118)":
    holds "logos.runtime_control.establish_route_request"

  test "[RUN-0408] logos.runtime_control.route_continuation (§9.3 l.2126)":
    holds "logos.runtime_control.route_continuation"

  test "[RUN-0409] logos.runtime_control.establish_route_response (§9.3 l.2131)":
    holds "logos.runtime_control.establish_route_response"

  test "[RUN-0410] logos.runtime_control.renew_route_request (§9.3 l.2137)":
    holds "logos.runtime_control.renew_route_request"

  test "[RUN-0411] logos.runtime_control.renew_route_response (§9.3 l.2142)":
    holds "logos.runtime_control.renew_route_response"

  test "[RUN-0412] logos.runtime_control.describe_provider_request (§9.3 l.2146)":
    holds "logos.runtime_control.describe_provider_request"

  test "[RUN-0413] logos.runtime_control.describe_provider_response (§9.3 l.2150)":
    holds "logos.runtime_control.describe_provider_response"

  test "[RUN-0414] logos.runtime_control.list_modules_request (§9.3 l.2161)":
    holds "logos.runtime_control.list_modules_request"

  test "[RUN-0415] logos.runtime_control.list_modules_response (§9.3 l.2168)":
    holds "logos.runtime_control.list_modules_response"

  test "[RUN-0416] logos.runtime_control.list_routes_request (§9.3 l.2173)":
    holds "logos.runtime_control.list_routes_request"

  test "[RUN-0417] logos.runtime_control.list_routes_response (§9.3 l.2180)":
    holds "logos.runtime_control.list_routes_response"

  test "[RUN-0418] logos.runtime_control.list_remote_listeners_request (§9.3 l.2185)":
    holds "logos.runtime_control.list_remote_listeners_request"

  test "[RUN-0419] logos.runtime_control.list_remote_listeners_response (§9.3 l.2190)":
    holds "logos.runtime_control.list_remote_listeners_response"

  test "[RUN-0420] logos.runtime_control.set_remote_listener_request (§9.3 l.2195)":
    holds "logos.runtime_control.set_remote_listener_request"

  test "[RUN-0421] logos.runtime_control.set_remote_listener_response (§9.3 l.2199)":
    holds "logos.runtime_control.set_remote_listener_response"

  test "[RUN-0422] logos.runtime_control.list_provider_exports_request (§9.3 l.2203)":
    holds "logos.runtime_control.list_provider_exports_request"

  test "[RUN-0423] logos.runtime_control.list_provider_exports_response (§9.3 l.2210)":
    holds "logos.runtime_control.list_provider_exports_response"

  test "[RUN-0424] logos.runtime_control.set_provider_export_request (§9.3 l.2215)":
    holds "logos.runtime_control.set_provider_export_request"

  test "[RUN-0425] logos.runtime_control.set_provider_export_response (§9.3 l.2219)":
    holds "logos.runtime_control.set_provider_export_response"

  test "[RUN-0426] logos.runtime_control.close_route_request (§9.3 l.2223)":
    holds "logos.runtime_control.close_route_request"

  test "[RUN-0427] logos.runtime_control.close_route_response (§9.3 l.2228)":
    holds "logos.runtime_control.close_route_response"

  test "[RUN-0428] logos.runtime_control.create_module_request (§9.3 l.2233)":
    holds "logos.runtime_control.create_module_request"

  test "[RUN-1131] logos.runtime_control.create_module_response, its result or an error (§9.3.2 l.2145)":
    armsHold(
      LogosNSRuntimeControlCreateModuleResponse,
      "logos.runtime_control.create_module_response",
    )

  test "[RUN-0430] logos.runtime_control.start_module_request (§9.3 l.2243)":
    holds "logos.runtime_control.start_module_request"

  test "[RUN-1132] logos.runtime_control.start_module_response, its result or an error (§9.3.2 l.2159)":
    armsHold(
      LogosNSRuntimeControlStartModuleResponse,
      "logos.runtime_control.start_module_response",
    )

  test "[RUN-0432] logos.runtime_control.stop_module_request (§9.3 l.2257)":
    holds "logos.runtime_control.stop_module_request"

  test "[RUN-1133] logos.runtime_control.stop_module_response, its result or an error (§9.3.2 l.2175)":
    armsHold(
      LogosNSRuntimeControlStopModuleResponse,
      "logos.runtime_control.stop_module_response",
    )

  test "[RUN-0434] logos.runtime_control.recover_module_request (§9.3 l.2271)":
    holds "logos.runtime_control.recover_module_request"

  test "[RUN-1134] logos.runtime_control.recover_module_response, its result or an error (§9.3.2 l.2190)":
    armsHold(
      LogosNSRuntimeControlRecoverModuleResponse,
      "logos.runtime_control.recover_module_response",
    )

  test "[RUN-0436] logos.runtime_control.report_failure_request (§9.3 l.2290)":
    holds "logos.runtime_control.report_failure_request"

  test "[RUN-0437] logos.runtime_control.report_failure_response (§9.3 l.2294)":
    holds "logos.runtime_control.report_failure_response"

  test "[RUN-0438] logos.runtime_control.shutdown_runtime_request (§9.3 l.2296)":
    holds "logos.runtime_control.shutdown_runtime_request"

  test "[RUN-0439] logos.runtime_control.shutdown_runtime_response (§9.3 l.2298)":
    holds "logos.runtime_control.shutdown_runtime_response"

  test "[RUN-0440] logos.runtime_control.execution_selection (§9.3 l.2300)":
    holds "logos.runtime_control.execution_selection"

  test "[RUN-0441] logos.runtime_control.get_execution_summary_request (§9.3 l.2319)":
    holds "logos.runtime_control.get_execution_summary_request"

  test "[RUN-0442] logos.runtime_control.get_execution_summary_response (§9.3 l.2323)":
    holds "logos.runtime_control.get_execution_summary_response"

  test "[RUN-0443] logos.runtime_control.get_readiness_request (§9.3 l.2332)":
    holds "logos.runtime_control.get_readiness_request"

  test "[RUN-0444] logos.runtime_control.get_readiness_response (§9.3 l.2338)":
    holds "logos.runtime_control.get_readiness_response"

  test "[RUN-0445] logos.runtime_control.permission_setting (§9.3 l.2348)":
    holds "logos.runtime_control.permission_setting"

  test "[RUN-0446] logos.runtime_control.permission_settings_state (§9.3 l.2362)":
    holds "logos.runtime_control.permission_settings_state"

  test "[RUN-0447] logos.runtime_control.get_permission_settings_request (§9.3 l.2369)":
    holds "logos.runtime_control.get_permission_settings_request"

  test "[RUN-0448] logos.runtime_control.get_permission_settings_response (§9.3 l.2373)":
    holds "logos.runtime_control.get_permission_settings_response"

  test "[RUN-0449] logos.runtime_control.update_permission_settings_request (§9.3 l.2378)":
    holds "logos.runtime_control.update_permission_settings_request"

  test "[RUN-1136] logos.runtime_control.update_permission_settings_response, its result or an error (§9.3.2 l.2301)":
    armsHold(
      LogosNSRuntimeControlUpdatePermissionSettingsResponse,
      "logos.runtime_control.update_permission_settings_response",
    )

  test "[RUN-0451] logos.runtime_control.permission_settings_changed_event (§9.3 l.2389)":
    holds "logos.runtime_control.permission_settings_changed_event"

  test "[RUN-0452] logos.runtime_control.get_configuration_schema_request (§9.3 l.2394)":
    holds "logos.runtime_control.get_configuration_schema_request"

  test "[RUN-0453] logos.runtime_control.get_configuration_schema_response (§9.3 l.2398)":
    holds "logos.runtime_control.get_configuration_schema_response"

  test "[RUN-0454] logos.runtime_control.get_configuration_summary_request (§9.3 l.2404)":
    holds "logos.runtime_control.get_configuration_summary_request"

  test "[RUN-0455] logos.runtime_control.get_configuration_summary_response (§9.3 l.2408)":
    holds "logos.runtime_control.get_configuration_summary_response"

  test "[RUN-0456] logos.runtime_control.get_configuration_request (§9.3 l.2413)":
    holds "logos.runtime_control.get_configuration_request"

  test "[RUN-0457] logos.runtime_control.get_configuration_response (§9.3 l.2417)":
    holds "logos.runtime_control.get_configuration_response"

  test "[RUN-0458] logos.runtime_control.update_configuration_request (§9.3 l.2422)":
    holds "logos.runtime_control.update_configuration_request"

  test "[RUN-1137] logos.runtime_control.update_configuration_response, its result or an error (§9.3.2 l.2356)":
    armsHold(
      LogosNSRuntimeControlUpdateConfigurationResponse,
      "logos.runtime_control.update_configuration_response",
    )

  test "[RUN-0460] logos.runtime_control.apply_configuration_request (§9.3 l.2443)":
    holds "logos.runtime_control.apply_configuration_request"

  test "[RUN-1138] logos.runtime_control.apply_configuration_response, its result or an error (§9.3.2 l.2369)":
    armsHold(
      LogosNSRuntimeControlApplyConfigurationResponse,
      "logos.runtime_control.apply_configuration_response",
    )

  test "[RUN-0462] logos.runtime_control.configuration_state_changed_event (§9.3 l.2454)":
    holds "logos.runtime_control.configuration_state_changed_event"

  test "[RUN-0463] logos.runtime_control.execution_state_changed_event (§9.3 l.2459)":
    holds "logos.runtime_control.execution_state_changed_event"

  test "[RUN-0464] logos.runtime_control.module_state_changed_event (§9.3 l.2469)":
    holds "logos.runtime_control.module_state_changed_event"

  test "[RUN-0465] logos.runtime_control.route_state_changed_event (§9.3 l.2479)":
    holds "logos.runtime_control.route_state_changed_event"

  test "[RUN-0876] logos.runtime_control.cursor (§9.3 l.1938)":
    holds "logos.runtime_control.cursor"

  test "[RUN-0877] logos.runtime_control.inventory_collection (§9.3 l.1939)":
    holds "logos.runtime_control.inventory_collection"

  test "[RUN-0878] logos.runtime_control.get_self_request (§9.3 l.2155)":
    holds "logos.runtime_control.get_self_request"

  test "[RUN-0879] logos.runtime_control.get_self_response (§9.3 l.2157)":
    holds "logos.runtime_control.get_self_response"

  test "[RUN-0880] logos.runtime_control.retire_module_request (§9.3 l.2283)":
    holds "logos.runtime_control.retire_module_request"

  test "[RUN-1135] logos.runtime_control.retire_module_response, its result or an error (§9.3.2 l.2203)":
    armsHold(
      LogosNSRuntimeControlRetireModuleResponse,
      "logos.runtime_control.retire_module_response",
    )

  test "[RUN-0882] logos.runtime_control.get_execution_permissions_request (§9.3 l.2353)":
    holds "logos.runtime_control.get_execution_permissions_request"

  test "[RUN-0883] logos.runtime_control.get_execution_permissions_response (§9.3 l.2355)":
    holds "logos.runtime_control.get_execution_permissions_response"

  test "[RUN-0884] logos.runtime_control.inventory_changed_event (§9.3 l.2465)":
    holds "logos.runtime_control.inventory_changed_event"

  test "[RUN-0886] a failure code outside the defined list is a failure_code like any other, and its decoding keeps it (§9.3 l.2493)":
    for code in ["a", "zz-not-defined-yet", "x".repeat(64)]:
      let v = cborMap((cbor("code"), cbor(code)))
      check model.g.check("logos.runtime_control.route_failure", v).isOk
      check LogosNSRuntimeControlRouteFailure.fromChecked(v).code == code
    check model.g.check("logos.runtime_control.failure_code", cbor("x".repeat(65))).isErr

  test "[RUN-0501] a unix-stream address carries path and none of host, port, server_name or alpn, under both rules and in the codec (§9.3 l.2741; I81)":
    # [4b-2 plan §1.3] Each map of the contract is closed, so each forbidden key
    # is refused by the unix-stream rule and by the address choice.
    let rules = [
      "logos.runtime_control.unix_stream_runtime_address",
      "logos.runtime_control.runtime_address",
    ]
    let transport = (cbor("transport"), cbor("unix-stream"))
    let path = (cbor("path"), cbor("/run/logos/x/logos_meter_module.sock"))
    let good = cborMap(transport, path)
    for rule in rules:
      check model.g.check(rule, good).isOk
    check LogosNSRuntimeControlUnixStreamRuntimeAddress.decode(encodeCbor(good)).isOk
    check LogosNSRuntimeControlRuntimeAddress.decode(encodeCbor(good)).isOk
    var bad = @[cborMap(transport)]
    for extra in [
      (cbor("host"), cbor("example.org")),
      (cbor("port"), cbor(443'u64)),
      (cbor("server_name"), cbor("example.org")),
      (cbor("alpn"), cbor("h3")),
    ]:
      bad.add(cborMap(transport, path, extra))
    for i, v in bad:
      checkpoint "case " & $i
      for rule in rules:
        check model.g.check(rule, v).isErr
      check LogosNSRuntimeControlUnixStreamRuntimeAddress.decode(encodeCbor(v)).isErr
      check LogosNSRuntimeControlRuntimeAddress.decode(encodeCbor(v)).isErr

suite "run.schema: remote Runtime enrollment (RUNTIME §9.3.7 l.2599-2632)":
  test "[RUN-1146] [RUN-1147] [RUN-1148] [RUN-1149] [RUN-1150] [TXT-0170] [TXT-0172] the enrollment rules are their own schema, with the names l.2602-2611 gives; its instance id restates §9.2's":
    # `uint64` is the common model's (INTERFACE §5.1), outside this schema.
    let doc = parseCddl(mirror("RNT/9.3.7.runtime-enrollment.cddl"), ["uint64"]).tryGet
    check doc.rules.mapIt(it.name) ==
      @[
        "logos.runtime_enrollment.remote_identity_profile",
        "logos.runtime_enrollment.remote_runtime_enrollment",
        "logos.runtime_enrollment.runtime_instance_id",
        "logos.runtime_enrollment.subject_public_key_info",
        "logos.runtime_enrollment.trust_anchor_id",
      ]
    let types = parseCddl(mirror("RNT/9.2.runtime-types.cddl")).tryGet
    let restated =
      doc.rules.filterIt(it.name == "logos.runtime_enrollment.runtime_instance_id")
    let original = types.rules.filterIt(it.name == "logos.runtime.runtime_instance_id")
    check restated.len == 1 and original.len == 1
    check toCbor(restated[0].typ) == toCbor(original[0].typ)

  test "[TXT-0171] [TXT-0173] the Runtime Control contract no longer defines or imports the enrollment records, so its introspection does not return them":
    for r in model.names:
      checkpoint r
      check "enrollment" notin r and "trust_anchor" notin r and
        "subject_public_key" notin r and "identity_profile" notin r
    check "runtime_enrollment" notin rcDocuments()[0]

suite "run.schema: the App B examples decode against the generated types (RUNTIME App B)":
  test "[RUN-1203] B.1, a Runtime endpoint":
    let v = appB("app-b.1.runtime-endpoint.edn")
    check model.g.check("logos.runtime_control.runtime_endpoint", v).isOk
    let e = LogosNSRuntimeControlRuntimeEndpoint.decode(encodeCbor(v)).tryGet
    check e.runtime_instance_id == Opt.some("de1d7cd9-4e0d-4f68-89fa-460fc3332e00")

  test "[RUN-1204] B.2, a module provider address":
    let v = appB("app-b.2.provider-address.edn")
    check model.g.check("logos.runtime.module_provider_address", v).isOk
    let a = LogosNSRuntimeModuleProviderAddress.decode(encodeCbor(v)).tryGet
    check a.provider == "provider-storage-local"

  test "[RUN-1205] [TXT-0145] [TXT-0570] B.3, a local module record with its execution":
    let v = appB("app-b.3.local-module-record.edn")
    check model.g.check("logos.runtime_control.module_record", v).isOk
    let r = LogosNSRuntimeControlModuleRecord.decode(encodeCbor(v)).tryGet
    check r.execution.get.revision == 1
    check r.instance == Opt.some("instance-storage-001")

  test "[RUN-1206] B.4, a remote facade module record":
    let v = appB("app-b.4.facade-module-record.edn")
    check model.g.check("logos.runtime_control.module_record", v).isOk
    let r = LogosNSRuntimeControlModuleRecord.decode(encodeCbor(v)).tryGet
    check r.remote.get.provider == Opt.some("provider-storage-remote")
    check r.instance.isNone

  test "[RUN-1208] [TXT-0571] B.5, a route resolved through a remote facade, with its invocation":
    let v = appB("app-b.5.facade-route.edn")
    check model.g.check("logos.runtime_control.route_record", v).isOk
    let r = LogosNSRuntimeControlRouteRecord.decode(encodeCbor(v)).tryGet
    check r.target_provider.provider == "provider-storage-remote"
    check r.invocation.isSome and r.expires_at == Opt.some(2000000000000'u64)
