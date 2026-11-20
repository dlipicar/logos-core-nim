## Runtime Control addresses and `connect_remote` endpoints for the M8 and
## IFC-0939 tests (re-pin P3b): `test_routes` (direct) and the boundary
## invariance script (direct and hosted).

import results
import logos_sdk/kit/rc_types
import ../../src/logos_core/runtime/rcaddress

export rcaddress

const OtherRuntime* = "0b6f3c3e-9d0f-4c1a-8f43-7a8f2b9b1a01" ## not the fixture's

proc tlsAddress*(profile = Opt.none(string)): LogosNSRuntimeControlRuntimeAddress =
  LogosNSRuntimeControlRuntimeAddress(
    kind:
      LogosNSRuntimeControlRuntimeAddressKind.logos_NS_runtime_control_Tls_tcp_runtime_address,
    arm_logos_NS_runtime_control_Tls_tcp_runtime_address: LogosNSRuntimeControlTlsTcpRuntimeAddress(
      host: "node-b.logos.example", port: 7443, profile: profile
    ),
  )

proc quicAddress*(
    alpn = Opt.none(string), profile = Opt.none(string)
): LogosNSRuntimeControlRuntimeAddress =
  LogosNSRuntimeControlRuntimeAddress(
    kind:
      LogosNSRuntimeControlRuntimeAddressKind.logos_NS_runtime_control_Quic_runtime_address,
    arm_logos_NS_runtime_control_Quic_runtime_address: LogosNSRuntimeControlQuicRuntimeAddress(
      host: "node-b.logos.example", port: 7443, alpn: alpn, profile: profile
    ),
  )

proc unixAddress*(profile = Opt.none(string)): LogosNSRuntimeControlRuntimeAddress =
  LogosNSRuntimeControlRuntimeAddress(
    kind:
      LogosNSRuntimeControlRuntimeAddressKind.logos_NS_runtime_control_Unix_stream_runtime_address,
    arm_logos_NS_runtime_control_Unix_stream_runtime_address: LogosNSRuntimeControlUnixStreamRuntimeAddress(
      path: "/run/logos.sock", profile: profile
    ),
  )

proc endpointOf*(
    id: Opt[string], address: LogosNSRuntimeControlRuntimeAddress
): seq[byte] =
  encode(
    LogosNSRuntimeControlRuntimeEndpoint(runtime_instance_id: id, address: address)
  ).tryGet

proc listenerAddress*(
    a: LogosNSRuntimeControlRuntimeAddress
): LogosNSRuntimeControlRemoteListenerAddress =
  a.remoteAddress.get
