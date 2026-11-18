## Owner B1 (2026-11-16); D27; G323: a `Signer` that holds the TLS key in the
## process, for tests only. Production TLS processes sign through the signing
## channel to logosd or a key holder (5-7a); this module exists only in test
## builds, and its marker lets the flake's `no-test-hooks` check find it in any
## deployment output.

{.push raises: [].}

when not defined(lcnTestHooks):
  {.error: "testsigner.nim holds the TLS key in the process: test builds only (D27)".}

import ../../base/testhooks
import ./[credential, signing]

export signing

testHooksMarker("tls_keysigner")

proc keySigner*(key: P256Key, role: TlsRole): Signer =
  ## Signs, with `key`, what `checkSignInput` accepts for `role`, the role
  ## fixed here as a signing channel fixes it; refuses the rest.
  result = proc(
      r: TlsRole, alg: uint16, input: seq[byte]
  ): Future[SignResult] {.async: (raises: [CancelledError]), gcsafe.} =
    if r != role or checkSignInput(role, alg, input).isErr:
      return refused()
    let sig = signP256(key, input)
    if sig.isErr:
      return unavailable()
    return signed(sig.get)

{.pop.}
