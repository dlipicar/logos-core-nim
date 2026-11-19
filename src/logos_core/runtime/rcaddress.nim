## M8 (re-pin P3b; RUNTIME §9.3.8 l.2703-2705; TRANSPORT §8.4 l.1183-1184,
## l.1299): the remote profile a Runtime Control address names. `tls-tcp`
## selects `logos.remote.tls-tcp` and `quic` selects `logos.remote.quic`; a
## present `profile` must name the selected one, and a `quic` address's
## present `alpn` must equal `logos.remote.quic`. The text selects no profile
## for `unix-stream` (Fable synthesis §14.1): no request input here takes one
## but `connect_remote`'s endpoint, which refuses every non-remote address
## (INTERFACE l.3876), so no rule below reads its `profile`.

{.push raises: [].}

import results
import logos_sdk/kit/rc_types

const
  RemoteTlsTcp* = "logos.remote.tls-tcp" ## the profile `tls-tcp` selects
  RemoteQuic* = "logos.remote.quic" ## the profile `quic` selects, and its ALPN

func mismatching*(a: LogosNSRuntimeControlTlsTcpRuntimeAddress): bool =
  ## [SPEC RUNTIME l.2704] A present `profile` other than `logos.remote.tls-tcp`.
  a.profile.isSome and a.profile.get != RemoteTlsTcp

func mismatching*(a: LogosNSRuntimeControlQuicRuntimeAddress): bool =
  ## [SPEC RUNTIME l.2704-2705] A present `profile` other than
  ## `logos.remote.quic`, or a present `alpn` other than that value.
  (a.profile.isSome and a.profile.get != RemoteQuic) or
    (a.alpn.isSome and a.alpn.get != RemoteQuic)

func mismatching*(a: LogosNSRuntimeControlRemoteListenerAddress): bool =
  case a.kind
  of LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Quic_runtime_address:
    a.arm_logos_NS_runtime_control_Quic_runtime_address.mismatching
  of LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Tls_tcp_runtime_address:
    a.arm_logos_NS_runtime_control_Tls_tcp_runtime_address.mismatching

func remoteAddress*(
    a: LogosNSRuntimeControlRuntimeAddress
): Opt[LogosNSRuntimeControlRemoteListenerAddress] =
  ## The address as a remote one; none for `unix-stream`, which selects no
  ## remote profile (INTERFACE l.3874, l.3876).
  case a.kind
  of LogosNSRuntimeControlRuntimeAddressKind.logos_NS_runtime_control_Quic_runtime_address:
    Opt.some(
      LogosNSRuntimeControlRemoteListenerAddress(
        kind:
          LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Quic_runtime_address,
        arm_logos_NS_runtime_control_Quic_runtime_address:
          a.arm_logos_NS_runtime_control_Quic_runtime_address,
      )
    )
  of LogosNSRuntimeControlRuntimeAddressKind.logos_NS_runtime_control_Tls_tcp_runtime_address:
    Opt.some(
      LogosNSRuntimeControlRemoteListenerAddress(
        kind:
          LogosNSRuntimeControlRemoteListenerAddressKind.logos_NS_runtime_control_Tls_tcp_runtime_address,
        arm_logos_NS_runtime_control_Tls_tcp_runtime_address:
          a.arm_logos_NS_runtime_control_Tls_tcp_runtime_address,
      )
    )
  of LogosNSRuntimeControlRuntimeAddressKind.logos_NS_runtime_control_Unix_stream_runtime_address:
    Opt.none(LogosNSRuntimeControlRemoteListenerAddress)

{.pop.}
