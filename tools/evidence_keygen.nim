## Writes a fresh call-evidence signing key for `call_audit.evidence`
## (docs/HOST-CONFIG.md; CA §9.1; DECISIONS I85): FIPS 205 SLH-DSA-SHA2-192s
## key generation from the operating-system CSPRNG (CAP-0402), the 96 raw
## secret-key bytes in a new file restricted to its owner (mode 0600) before
## they are written, and the 48-byte public key printed in hex for the
## verifiers' trust input. An evidence key is never a package signing key
## (CAP-0401): `lcn-pkg keygen` makes those. Under logosd, `logosctl init`
## makes the key and its binding instead (docs/DAEMON.md).
##
##   nim c -r tools/evidence_keygen.nim /abs/path/evidence.key

import std/os
import ../src/logos_core/base/hex
import ../src/logos_core/runtime/evidence

proc main(): int =
  if paramCount() != 1 or not isAbsolute(paramStr(1)):
    stderr.writeLine "usage: evidence_keygen ABSOLUTE-PATH"
    return 2
  let path = paramStr(1)
  var (sk, pk) = generateEvidenceKey().valueOr:
    stderr.writeLine error
    return 1
  defer:
    sk.clear()
  writeEvidenceKeyFile(path, sk).isOkOr:
    stderr.writeLine error
    return 1
  echo "public key: ", pk.toHex
  0

quit(main())
