## BLAKE3 over the official C implementation, vendored in `blake3/` (see
## `blake3/VERSION`; refresh with `tools/update-blake3.sh`).

{.push raises: [].}

import std/os

const
  blake3Dir = currentSourcePath().parentDir() / "blake3"
  blake3Header = blake3Dir / "blake3.h"

  Blake3OutLen* = 32
  Blake3KeyLen* = 32

when defined(amd64):
  when defined(windows):
    {.compile: "blake3/blake3_sse2_x86-64_windows_gnu.S".}
    {.compile: "blake3/blake3_sse41_x86-64_windows_gnu.S".}
    {.compile: "blake3/blake3_avx2_x86-64_windows_gnu.S".}
    {.compile: "blake3/blake3_avx512_x86-64_windows_gnu.S".}
  else:
    {.compile: "blake3/blake3_sse2_x86-64_unix.S".}
    {.compile: "blake3/blake3_sse41_x86-64_unix.S".}
    {.compile: "blake3/blake3_avx2_x86-64_unix.S".}
    {.compile: "blake3/blake3_avx512_x86-64_unix.S".}
elif defined(arm64):
  {.compile: "blake3/blake3_neon.c".}
else:
  {.passC: "-DBLAKE3_NO_SSE2 -DBLAKE3_NO_SSE41 -DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512".}

{.compile: "blake3/blake3.c".}
{.compile: "blake3/blake3_dispatch.c".}
{.compile: "blake3/blake3_portable.c".}

type
  Blake3Hasher* {.importc: "blake3_hasher", header: blake3Header, bycopy.} = object

  Blake3Digest* = array[Blake3OutLen, byte]

proc cVersion(): cstring {.importc: "blake3_version", header: blake3Header.}
proc cInit(
  self: ptr Blake3Hasher
) {.importc: "blake3_hasher_init", header: blake3Header.}

proc cInitKeyed(
  self: ptr Blake3Hasher, key: ptr byte
) {.importc: "blake3_hasher_init_keyed", header: blake3Header.}

proc cInitDeriveKeyRaw(
  self: ptr Blake3Hasher, context: pointer, contextLen: csize_t
) {.importc: "blake3_hasher_init_derive_key_raw", header: blake3Header.}

proc cUpdate(
  self: ptr Blake3Hasher, input: pointer, inputLen: csize_t
) {.importc: "blake3_hasher_update", header: blake3Header.}

proc cFinalize(
  self: ptr Blake3Hasher, output: ptr byte, outLen: csize_t
) {.importc: "blake3_hasher_finalize", header: blake3Header.}

proc blake3Version*(): string =
  $cVersion()

proc init*(h: var Blake3Hasher) =
  cInit(addr h)

proc initKeyed*(h: var Blake3Hasher, key: array[Blake3KeyLen, byte]) =
  cInitKeyed(addr h, unsafeAddr key[0])

proc initDeriveKey*(h: var Blake3Hasher, context: openArray[byte]) =
  cInitDeriveKeyRaw(
    addr h, (if context.len > 0: unsafeAddr context[0] else: nil), csize_t(context.len)
  )

proc update*(h: var Blake3Hasher, data: openArray[byte]) =
  if data.len > 0:
    cUpdate(addr h, unsafeAddr data[0], csize_t(data.len))

proc update*(h: var Blake3Hasher, data: openArray[char]) =
  if data.len > 0:
    cUpdate(addr h, unsafeAddr data[0], csize_t(data.len))

proc finish*(h: var Blake3Hasher, output: var openArray[byte]) =
  ## Extendable output: fills `output` with its length's worth of hash.
  if output.len > 0:
    cFinalize(addr h, addr output[0], csize_t(output.len))

proc finish*(h: var Blake3Hasher): Blake3Digest =
  var digest: Blake3Digest
  h.finish(digest)
  digest

func blake3*(data: openArray[byte]): Blake3Digest =
  ## One-shot hash. A `func`: the hasher state is local, so the C calls have no
  ## observable side effect.
  var digest: Blake3Digest
  {.cast(noSideEffect).}:
    var h: Blake3Hasher
    h.init()
    h.update(data)
    digest = h.finish()
  digest
