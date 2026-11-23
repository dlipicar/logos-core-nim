## [IMPL-DECISION G409] Compiles the BoringSSL binding's objects, libssl's among
## them, into a nimcache for the flake check `logosd-no-ssl` (`nossl.nim`). Its
## binary, linked without dead stripping, holds them all, and the check must
## fail on it. It is never run. Nim 2.2.14 links under `--noLinking:on` too
## (upstream ISSUES 196), so the C++ runtime is named on Linux, as
## `transport/tls/p256.nim` does.

import boringssl

when defined(linux) and not defined(android):
  {.passl: "-lstdc++".}

discard SSL_library_init()
