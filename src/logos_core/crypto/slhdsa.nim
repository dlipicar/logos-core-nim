## SLH-DSA-SHA2-192s (FIPS 205) over slhdsa-c, the portable C90
## implementation of the PQ Code Package project, vendored in `slhdsa/` (see
## `slhdsa/VERSION`; refresh with `tools/update-slhdsa.sh`). Only what the Logos
## signing profiles use is compiled: the SHA2-192s parameter set, the pure
## functions with a context (PM §4.3 and §4.5 pass a zero-length one) and the
## internal functions the NIST ACVP tests exercise. HashSLH-DSA and the SHAKE
## parameter sets are not built: the profiles forbid them [SPEC PM §4.3].
##
## Randomness comes from the operating system's CSPRNG (`std/sysrand`) unless a
## caller passes another `RandomSource`; key generation and hedged signing fail
## when it cannot be read [SPEC PM §4.3].

{.push raises: [].}

import std/[os, sysrand]
import results

export results

const
  slhDir = currentSourcePath().parentDir() / "slhdsa"
  slhHeader = slhDir / "slh_dsa.h"

  N* = 24 ## [FIPS 205 Table 2] n for SLH-DSA-SHA2-192s: the seed and hash size
  PublicKeyBytes* = 2 * N ## `PK.seed || PK.root` [SPEC PM §4.3]
  SecretKeyBytes* = 4 * N ## `SK.seed || SK.prf || PK.seed || PK.root`
  SignatureBytes* = 16_224 ## [SPEC PM §4.3] [FIPS 205 Table 2]
  MaxContextBytes* = 255 ## [FIPS 205 Algorithm 22]
  AlgorithmName* = "SLH-DSA-SHA2-192s"

{.compile: "slhdsa/sha2_256.c".}
{.compile: "slhdsa/sha2_512.c".}
{.compile: "slhdsa/slh_sha2.c".}
{.compile: "slhdsa/slh_dsa.c".}

type
  SlhParam {.importc: "slh_param_t", header: slhHeader, incompleteStruct.} = object

  PublicKey* = array[PublicKeyBytes, byte]
  SecretKey* = array[SecretKeyBytes, byte]
    ## Secret material; callers clear it after use (`clear`).
  Seed* = array[N, byte]

  RandomSource* = proc(dest: var openArray[byte]): bool {.nimcall, gcsafe, raises: [].}
    ## Fills `dest` with fresh random bytes, or returns false.

var sha2_192s {.importc: "slh_dsa_sha2_192s", header: slhHeader.}: SlhParam

proc cAlgId(prm: ptr SlhParam): cstring {.importc: "slh_alg_id", header: slhHeader.}
proc cPkSize(prm: ptr SlhParam): csize_t {.importc: "slh_pk_sz", header: slhHeader.}
proc cSkSize(prm: ptr SlhParam): csize_t {.importc: "slh_sk_sz", header: slhHeader.}
proc cSigSize(prm: ptr SlhParam): csize_t {.importc: "slh_sig_sz", header: slhHeader.}

proc cKeygenInternal(
  sk, pk: ptr uint8, skSeed, skPrf, pkSeed: ptr uint8, prm: ptr SlhParam
): cint {.importc: "slh_keygen_internal", header: slhHeader.}

proc cSignInternal(
  sig, m: ptr uint8, mSz: csize_t, sk, addrnd: ptr uint8, prm: ptr SlhParam
): csize_t {.importc: "slh_sign_internal", header: slhHeader.}

proc cSign(
  sig, m: ptr uint8,
  mSz: csize_t,
  ctx: ptr uint8,
  ctxSz: csize_t,
  sk, addrnd: ptr uint8,
  prm: ptr SlhParam,
): csize_t {.importc: "slh_sign", header: slhHeader.}

proc cVerifyInternal(
  m: ptr uint8,
  mSz: csize_t,
  sig: ptr uint8,
  sigSz: csize_t,
  pk: ptr uint8,
  prm: ptr SlhParam,
): cint {.importc: "slh_verify_internal", header: slhHeader.}

proc cVerify(
  m: ptr uint8,
  mSz: csize_t,
  sig: ptr uint8,
  sigSz: csize_t,
  ctx: ptr uint8,
  ctxSz: csize_t,
  pk: ptr uint8,
  prm: ptr SlhParam,
): cint {.importc: "slh_verify", header: slhHeader.}

template at(s: openArray[byte]): ptr uint8 =
  ## The first byte, or null for an empty input (every C function takes a
  ## length beside it).
  (if s.len == 0: nil else: cast[ptr uint8](unsafeAddr s[0]))

proc osRandom*(dest: var openArray[byte]): bool =
  ## The operating system's CSPRNG (`std/sysrand`).
  urandom(dest)

proc parameters*(): tuple[name: string, pk, sk, sig: int] =
  ## What the vendored code reports for the parameter set it signs with.
  (
    $cAlgId(addr sha2_192s),
    int(cPkSize(addr sha2_192s)),
    int(cSkSize(addr sha2_192s)),
    int(cSigSize(addr sha2_192s)),
  )

proc clear*(k: var SecretKey) =
  ## Overwrites secret key material.
  zeroMem(addr k[0], k.len)

func publicKey*(sk: SecretKey): PublicKey =
  ## [FIPS 205 §9.1] The public key is the secret key's last 2n bytes.
  for i in 0 ..< PublicKeyBytes:
    result[i] = sk[2 * N + i]

proc keyPairFromSeeds*(skSeed, skPrf, pkSeed: Seed): (SecretKey, PublicKey) =
  ## [FIPS 205 Algorithm 18] `slh_keygen_internal`, for known-answer tests.
  var sk: SecretKey
  var pk: PublicKey
  doAssert cKeygenInternal(
    addr sk[0],
    addr pk[0],
    unsafeAddr skSeed[0],
    unsafeAddr skPrf[0],
    unsafeAddr pkSeed[0],
    addr sha2_192s,
  ) == 0
  (sk, pk)

proc generateKeyPair*(
    random: RandomSource = osRandom
): Result[(SecretKey, PublicKey), string] =
  ## [FIPS 205 Algorithm 21] `slh_keygen` with seeds from `random`; fails when
  ## it cannot supply them [SPEC PM §4.3].
  var seeds: array[3 * N, byte]
  if not random(seeds):
    zeroMem(addr seeds[0], seeds.len)
    return err("no randomness could be obtained")
  var a, b, c: Seed
  copyMem(addr a[0], addr seeds[0], N)
  copyMem(addr b[0], addr seeds[N], N)
  copyMem(addr c[0], addr seeds[2 * N], N)
  zeroMem(addr seeds[0], seeds.len)
  let kp = keyPairFromSeeds(a, b, c)
  zeroMem(addr a[0], N)
  zeroMem(addr b[0], N)
  ok(kp)

proc signWith(
    sk: SecretKey, message, context: openArray[byte], addrnd: ptr uint8, internal: bool
): Result[seq[byte], string] =
  if not internal and context.len > MaxContextBytes:
    return err("a context is at most 255 bytes")
  var sig = newSeq[byte](SignatureBytes)
  let n =
    if internal:
      cSignInternal(
        addr sig[0],
        at(message),
        csize_t(message.len),
        unsafeAddr sk[0],
        addrnd,
        addr sha2_192s,
      )
    else:
      cSign(
        addr sig[0],
        at(message),
        csize_t(message.len),
        at(context),
        csize_t(context.len),
        unsafeAddr sk[0],
        addrnd,
        addr sha2_192s,
      )
  if int(n) != SignatureBytes:
    return err("signing failed")
  ok(sig)

proc sign*(
    sk: SecretKey,
    message: openArray[byte],
    context: openArray[byte] = [],
    random: RandomSource = osRandom,
): Result[seq[byte], string] =
  ## [FIPS 205 Algorithm 22] Pure `slh_sign`, hedged with n fresh bytes from
  ## `random`; fails when it cannot supply them [SPEC PM §4.3].
  var addrnd: Seed
  if not random(addrnd):
    return err("no randomness could be obtained")
  signWith(sk, message, context, addr addrnd[0], internal = false)

proc signDeterministic*(
    sk: SecretKey, message: openArray[byte], context: openArray[byte] = []
): Result[seq[byte], string] =
  ## [FIPS 205 Algorithm 22] Pure `slh_sign`, deterministic variant
  ## (`opt_rand = PK.seed`): for known-answer tests and reproducible fixtures.
  signWith(sk, message, context, nil, internal = false)

proc signWithRandomness*(
    sk: SecretKey, message, context: openArray[byte], addrnd: Seed
): Result[seq[byte], string] =
  ## [FIPS 205 Algorithm 22] Pure `slh_sign` with the given additional
  ## randomness, for known-answer tests.
  signWith(sk, message, context, unsafeAddr addrnd[0], internal = false)

proc signInternal*(
    sk: SecretKey, message: openArray[byte], addrnd: Opt[Seed]
): Result[seq[byte], string] =
  ## [FIPS 205 Algorithm 19] `slh_sign_internal`, for known-answer tests.
  if addrnd.isSome:
    var r = addrnd.get
    return signWith(sk, message, [], addr r[0], internal = true)
  signWith(sk, message, [], nil, internal = true)

proc verify*(
    pk: openArray[byte],
    message, signature: openArray[byte],
    context: openArray[byte] = [],
): bool =
  ## [FIPS 205 Algorithm 24] Pure `slh_verify`. A key or signature of any other
  ## length fails without being repaired [SPEC PM §4.3].
  if pk.len != PublicKeyBytes or signature.len != SignatureBytes or
      context.len > MaxContextBytes:
    return false
  cVerify(
    at(message),
    csize_t(message.len),
    at(signature),
    csize_t(signature.len),
    at(context),
    csize_t(context.len),
    at(pk),
    addr sha2_192s,
  ) == 1

proc verifyInternal*(pk: openArray[byte], message, signature: openArray[byte]): bool =
  ## [FIPS 205 Algorithm 20] `slh_verify_internal`, for known-answer tests.
  if pk.len != PublicKeyBytes or signature.len != SignatureBytes:
    return false
  cVerifyInternal(
    at(message),
    csize_t(message.len),
    at(signature),
    csize_t(signature.len),
    at(pk),
    addr sha2_192s,
  ) == 1
