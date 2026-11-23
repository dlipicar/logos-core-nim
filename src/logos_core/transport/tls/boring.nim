## D28, I99: the TLS engine's view of the pinned BoringSSL binding
## (nim-boringssl 0.0.16): the binding with its link rules and libcrypto
## helpers (`p256.nim`, which imports the binding itself), and libssl's
## constants. Each test suite and program that imports either compiles all of
## BoringSSL, so they are imported only under `transport/tls/`, and no module
## outside that tree imports `tls` except the TLS programs and their one suite.
## logosd and logosctl may reach `p256.nim` but never this module (the layers
## lint's `daemon-no-tls`; Tier 5 step 5-7a-1).

{.push raises: [].}

import ./p256

export p256

const
  TlsextNametypeHostName* = 0.cint ## `TLSEXT_NAMETYPE_host_name`
  AlertBadCertificate* = 42'u8
  AlertInternalError* = 80'u8

{.pop.}
