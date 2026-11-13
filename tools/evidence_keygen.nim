## Writes a fresh call-evidence signing key for `call_audit.evidence`
## (docs/HOST-CONFIG.md; CA §9.1; DECISIONS I85): FIPS 205 SLH-DSA-SHA2-192s
## key generation from the operating-system CSPRNG (CAP-0402), the 96 raw
## secret-key bytes in a new file restricted to its owner (mode 0600) before
## they are written, and the 48-byte public key printed in hex for the
## verifiers' trust input. An evidence key is never a package signing key
## (CAP-0401): `lcn-pkg keygen` makes those.
##
##   nim c -r tools/evidence_keygen.nim /abs/path/evidence.key

import std/[os, posix]
import ../src/logos_core/base/hex
import ../src/logos_core/crypto/slhdsa

proc main(): int =
  if paramCount() != 1 or not isAbsolute(paramStr(1)):
    stderr.writeLine "usage: evidence_keygen ABSOLUTE-PATH"
    return 2
  let path = paramStr(1)
  var (sk, pk) = generateKeyPair().valueOr:
    stderr.writeLine error
    return 1
  defer:
    sk.clear()
  # Created exclusively with mode 0600, then written.
  let fd = posix.open(cstring(path), O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
  if fd < 0:
    stderr.writeLine path &
      " cannot be created (it may exist; a key is never overwritten)"
    return 1
  let n = posix.write(fd, addr sk[0], SecretKeyBytes)
  discard posix.close(fd)
  if n != SecretKeyBytes:
    stderr.writeLine "the key could not be written"
    discard tryRemoveFile(path)
    return 1
  echo "public key: ", pk.toHex
  0

quit(main())
