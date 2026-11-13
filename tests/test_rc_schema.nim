## The Runtime Types and Runtime Control contract (RUNTIME §9.2, §9.3), rule by
## rule (DECISIONS I88, W2): values built from the accepted model validate and
## round-trip byte for byte through `runtime/rc_types.nim`; values outside a
## bound are refused (`support/schemasuite`). One test per rule, named by its
## requirement id.

import std/strutils
import unittest2
import ../src/logos_core/runtime/rc_types
import ./support/schemasuite

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
  "logos.runtime_control.remote_identity_profile",
  "logos.runtime_control.trust_anchor_id",
  "logos.runtime_control.subject_public_key_info",
  "logos.runtime_control.remote_runtime_enrollment",
  "logos.runtime_control.remote_listener_address",
  "logos.runtime_control.remote_listener_record",
  "logos.runtime_control.provider_export_record",
  "logos.runtime_control.remote_provider_target",
  "logos.runtime_control.execution_state", "logos.runtime_control.module_record",
  "logos.runtime_control.invocation_descriptor", "logos.runtime_control.route_failure",
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

  test "[RUN-0386] logos.runtime_control.route_state (§9.3 l.1964)":
    holds "logos.runtime_control.route_state"

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

  test "[RUN-0392] logos.runtime_control.remote_identity_profile (§9.3 l.2005)":
    holds "logos.runtime_control.remote_identity_profile"

  test "[RUN-0393] logos.runtime_control.trust_anchor_id (§9.3 l.2009)":
    holds "logos.runtime_control.trust_anchor_id"

  test "[RUN-0394] logos.runtime_control.subject_public_key_info (§9.3 l.2010)":
    holds "logos.runtime_control.subject_public_key_info"

  test "[RUN-0395] logos.runtime_control.remote_runtime_enrollment (§9.3 l.2012)":
    holds "logos.runtime_control.remote_runtime_enrollment"

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

  test "[RUN-0401] logos.runtime_control.module_record (§9.3 l.2058)":
    holds "logos.runtime_control.module_record"

  test "[RUN-0402] logos.runtime_control.invocation_descriptor (§9.3 l.2073)":
    holds "logos.runtime_control.invocation_descriptor"

  test "[RUN-0403] logos.runtime_control.route_failure (§9.3 l.2088)":
    holds "logos.runtime_control.route_failure"

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

  test "[RUN-0429] logos.runtime_control.create_module_response (§9.3 l.2238)":
    holds "logos.runtime_control.create_module_response"

  test "[RUN-0430] logos.runtime_control.start_module_request (§9.3 l.2243)":
    holds "logos.runtime_control.start_module_request"

  test "[RUN-0431] logos.runtime_control.start_module_response (§9.3 l.2250)":
    holds "logos.runtime_control.start_module_response"

  test "[RUN-0432] logos.runtime_control.stop_module_request (§9.3 l.2257)":
    holds "logos.runtime_control.stop_module_request"

  test "[RUN-0433] logos.runtime_control.stop_module_response (§9.3 l.2264)":
    holds "logos.runtime_control.stop_module_response"

  test "[RUN-0434] logos.runtime_control.recover_module_request (§9.3 l.2271)":
    holds "logos.runtime_control.recover_module_request"

  test "[RUN-0435] logos.runtime_control.recover_module_response (§9.3 l.2277)":
    holds "logos.runtime_control.recover_module_response"

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

  test "[RUN-0450] logos.runtime_control.update_permission_settings_response (§9.3 l.2384)":
    holds "logos.runtime_control.update_permission_settings_response"

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

  test "[RUN-0459] logos.runtime_control.update_configuration_response (§9.3 l.2437)":
    holds "logos.runtime_control.update_configuration_response"

  test "[RUN-0460] logos.runtime_control.apply_configuration_request (§9.3 l.2443)":
    holds "logos.runtime_control.apply_configuration_request"

  test "[RUN-0461] logos.runtime_control.apply_configuration_response (§9.3 l.2448)":
    holds "logos.runtime_control.apply_configuration_response"

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

  test "[RUN-0881] logos.runtime_control.retire_module_response (§9.3 l.2288)":
    holds "logos.runtime_control.retire_module_response"

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
