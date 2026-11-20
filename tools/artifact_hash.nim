## Prints a file's BLAKE3-256 in hex: the logosd package compiles the companion
## `liblcn_call`'s digest into logosd with it (`-d:lcnCallArtifactHash`; Tier 5
## step N-2b; DECISIONS G343). `flake.nix` runs it on the library's final store
## file, so the digest is of the bytes the Module Loader will check.

import std/os
import logos_sdk/crypto/blake3
import logos_sdk/base/hex

proc main(): int =
  if paramCount() != 1:
    stderr.writeLine("usage: artifact_hash FILE")
    return 1
  let path = paramStr(1)
  var data: string
  try:
    data = readFile(path)
  except IOError as e:
    stderr.writeLine(path & ": " & e.msg)
    return 1
  echo toHex(blake3(data.toOpenArrayByte(0, data.high)))
  0

when isMainModule:
  quit(main())
