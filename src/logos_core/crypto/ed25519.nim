## Ed25519 (RFC 8032) for the `logos.package-signing.cose-sign1-ed25519`
## profile (PM §4.3), over BoringSSL [D28, IMPL-DECISION G135].
##
## BoringSSL's `ED25519_verify` checks S < L and compares encoded points
## cofactorlessly, but decodes points leniently: a non-canonical y is reduced
## and small-order points are accepted, so a small-order public key verifies a
## forged signature for every message. `verify` adds the checks that make the
## verdicts libsodium's (`crypto_sign_verify_detached`) [IMPL-DECISION G42]:
##
## - S < L (also in BoringSSL; kept here so the rule is in one place);
## - R is not a small-order encoding;
## - A is canonically encoded (y < p) and not a small-order encoding.
##
## The small-order encodings are libsodium's blocklist; tests check that it
## equals the set the oracle derives from the curve (oracle/ed25519.py).

{.push raises: [].}

import boringssl
import results

export results

# BoringSSL is C++. Nim links a mixed C/C++ build through the C++ driver, which
# brings the C++ runtime in, unless the configuration pins the linker: nixpkgs'
# Nim sets `gcc.linkerexe = $CC`, so on Linux the C driver links and the runtime
# must be named. macOS builds link without it. Nim's `linux` includes Android,
# whose NDK has only libc++; it is linked statically, so a binary needs no
# libc++_shared.so beside it (DECISIONS I44, I46).
when defined(android):
  {.passl: "-lc++_static -lc++abi".}
elif defined(linux):
  {.passl: "-lstdc++".}

const
  PublicKeyLen* = 32
  SignatureLen* = 64
  SeedLen* = 32

type
  PublicKey* = array[PublicKeyLen, byte]
  Signature* = array[SignatureLen, byte]
  Seed* = array[SeedLen, byte]

  SigningKey* = object
    ## BoringSSL's 64-byte private key: the seed, then the public key.
    raw: array[64, byte]

  KeyFailure* = enum
    kfLength = "not 32 bytes"
    kfNonCanonical = "a non-canonical point encoding"
    kfSmallOrder = "a small-order point"

func hexArray(s: static string): array[32, byte] {.compileTime.} =
  doAssert s.len == 64
  var a: array[32, byte]
  for i in 0 ..< 32:
    var v = 0
    for c in s[2 * i .. 2 * i + 1]:
      v =
        v * 16 + (
          case c
          of '0' .. '9': ord(c) - ord('0')
          of 'a' .. 'f': ord(c) - ord('a') + 10
          else:
            raiseAssert "not hex"
        )
    a[i] = byte(v)
  a

const
  GroupOrder =
    hexArray("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")
    ## L = 2^252 + 27742317777372353535851937790883648493, little-endian

  SmallOrderEncodings* = [
    hexArray("0000000000000000000000000000000000000000000000000000000000000000"),
      # y = 0: order 4
    hexArray("0100000000000000000000000000000000000000000000000000000000000000"),
      # y = 1: the identity
    hexArray("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05"),
      # order 8
    hexArray("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a"),
      # order 8
    hexArray("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
      # y = p - 1: order 2
    hexArray("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
      # y = p: non-canonical y = 0
    hexArray("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
      # y = p + 1: non-canonical identity
  ]
    ## [IMPL-DECISION G42] The 255-bit y values (sign bit cleared) that name a
    ## point of order 1, 2, 4 or 8, canonical or not: libsodium's
    ## `ge25519_has_small_order` blocklist.

func isCanonicalScalar*(s: openArray[byte]): bool =
  ## S < L for a 32-byte little-endian scalar [IMPL-DECISION G42].
  if s.len != 32:
    return false
  for i in countdown(31, 0):
    if s[i] != GroupOrder[i]:
      return s[i] < GroupOrder[i]
  false

func isCanonicalPoint*(e: openArray[byte]): bool =
  ## The encoded y, sign bit cleared, is below p = 2^255 - 19
  ## [IMPL-DECISION G42].
  if e.len != 32:
    return false
  if (e[31] and 0x7f) != 0x7f:
    return true
  for i in 1 .. 30:
    if e[i] != 0xff:
      return true
  e[0] < 0xed

func hasSmallOrder*(e: openArray[byte]): bool =
  ## The encoding names a small-order point, whatever its sign bit
  ## [IMPL-DECISION G42].
  if e.len != 32:
    return false
  for bad in SmallOrderEncodings:
    var same = (e[31] and 0x7f) == bad[31]
    for i in 0 .. 30:
      same = same and e[i] == bad[i]
    if same:
      return true
  false

func checkPublicKey*(e: openArray[byte]): Result[PublicKey, KeyFailure] =
  ## A public key as trust input admits it [IMPL-DECISION G42]: 32 bytes, a
  ## canonical encoding, not small-order. A key that is not a curve point
  ## passes here and verifies nothing.
  if e.len != PublicKeyLen:
    return err(kfLength)
  if not isCanonicalPoint(e):
    return err(kfNonCanonical)
  if hasSmallOrder(e):
    return err(kfSmallOrder)
  var k: PublicKey
  for i in 0 ..< PublicKeyLen:
    k[i] = e[i]
  ok(k)

template bytesPtr(m: openArray[byte]): ptr uint8 =
  if m.len == 0:
    nil
  else:
    cast[ptr uint8](unsafeAddr m[0])

proc keyFromSeed*(seed: Seed): SigningKey =
  ## RFC 8032 §5.1.5 key generation from a 32-byte seed.
  var
    pk: array[32'i64, uint8]
    sk: array[64'i64, uint8]
    s: array[32'i64, uint8]
  for i in 0 ..< SeedLen:
    s[i] = seed[i]
  ED25519_keypair_from_seed(pk, sk, s)
  var k: SigningKey
  for i in 0 ..< 64:
    k.raw[i] = sk[i]
  k

func publicKey*(k: SigningKey): PublicKey =
  var pk: PublicKey
  for i in 0 ..< PublicKeyLen:
    pk[i] = k.raw[SeedLen + i]
  pk

proc sign*(k: SigningKey, msg: openArray[byte]): Signature =
  ## RFC 8032 §5.1.6: deterministic, so equal inputs give equal signatures.
  var
    sig: array[64'i64, uint8]
    sk: array[64'i64, uint8]
  for i in 0 ..< 64:
    sk[i] = k.raw[i]
  let rc = ED25519_sign(sig, bytesPtr(msg), csize_t(msg.len), sk)
  doAssert rc == 1, "ED25519_sign fails only on allocation failure"
  var s: Signature
  for i in 0 ..< SignatureLen:
    s[i] = sig[i]
  s

proc verify*(pk: PublicKey, msg: openArray[byte], sig: Signature): bool =
  ## [IMPL-DECISION G42, G135] libsodium's verdict: the checks above, then
  ## BoringSSL's cofactorless verification.
  if not isCanonicalScalar(sig.toOpenArray(32, 63)) or
      hasSmallOrder(sig.toOpenArray(0, 31)):
    return false
  if not isCanonicalPoint(pk) or hasSmallOrder(pk):
    return false
  var
    s: array[64'i64, uint8]
    a: array[32'i64, uint8]
  for i in 0 ..< SignatureLen:
    s[i] = sig[i]
  for i in 0 ..< PublicKeyLen:
    a[i] = pk[i]
  ED25519_verify(bytesPtr(msg), csize_t(msg.len), s, a) == 1

proc verify*(pk: openArray[byte], msg: openArray[byte], sig: openArray[byte]): bool =
  ## `verify` for byte strings of any length: anything but 32 and 64 fails.
  if pk.len != PublicKeyLen or sig.len != SignatureLen:
    return false
  var
    k: PublicKey
    s: Signature
  for i in 0 ..< PublicKeyLen:
    k[i] = pk[i]
  for i in 0 ..< SignatureLen:
    s[i] = sig[i]
  verify(k, msg, s)
