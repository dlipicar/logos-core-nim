## FIPS 205 SLH-DSA-SHA2-192s over the vendored slhdsa-c: the NIST ACVP
## known-answer cases for key generation, signing and verification (pure and
## internal interfaces), and the PM §4.3 signing rules the wrapper enforces.

import std/[json, sequtils]
import unittest2
import ../src/logos_core/crypto/slhdsa
import ../src/logos_core/base/hex
import ./support/specdata

proc bytes(s: string): seq[byte] =
  hex.fromHex(s).get

proc seed(s: string): Seed =
  let b = bytes(s)
  doAssert b.len == N
  copyMem(addr result[0], unsafeAddr b[0], N)

proc secretKey(s: string): SecretKey =
  let b = bytes(s)
  doAssert b.len == SecretKeyBytes
  copyMem(addr result[0], unsafeAddr b[0], SecretKeyBytes)

let acvp = parseJson(readRepoFile("tests/vectors/slhdsa/acvp-sha2-192s.json"))

const signingCases =
  when defined(release):
    high(int)
  else:
    2
  ## Signing with the small parameter sets is slow without optimization: a
  ## debug build signs the first cases of each group, a release build all.

suite "crypto.slhdsa: SLH-DSA-SHA2-192s (FIPS 205) over slhdsa-c":
  test "the vendored code reports the PM §4.3 sizes for SLH-DSA-SHA2-192s":
    check parameters() == (
      AlgorithmName, PublicKeyBytes, SecretKeyBytes, SignatureBytes
    )
    check (PublicKeyBytes, SignatureBytes) == (48, 16_224)

  test "ACVP keyGen: slh_keygen_internal":
    check acvp["parameterSet"].getStr == AlgorithmName
    check acvp["keyGen"].len == 10
    for c in acvp["keyGen"]:
      let (sk, pk) = keyPairFromSeeds(
        seed(c["skSeed"].getStr), seed(c["skPrf"].getStr), seed(c["pkSeed"].getStr)
      )
      checkpoint "tcId " & $c["tcId"].getInt
      check @sk == bytes(c["sk"].getStr)
      check @pk == bytes(c["pk"].getStr)
      check publicKey(sk) == pk

  test "ACVP sigGen: pure and internal, deterministic and hedged":
    var perGroup: seq[(int, int)]
    var ran = 0
    for c in acvp["sigGen"]:
      let g = c["tgId"].getInt
      let seen = perGroup.filterIt(it[0] == g).len
      if seen >= signingCases:
        continue
      perGroup.add (g, c["tcId"].getInt)
      checkpoint "tgId " & $g & " tcId " & $c["tcId"].getInt
      let sk = secretKey(c["sk"].getStr)
      let msg = bytes(c["message"].getStr)
      let want = bytes(c["signature"].getStr)
      let rnd =
        if c["deterministic"].getBool:
          Opt.none(Seed)
        else:
          Opt.some(seed(c["additionalRandomness"].getStr))
      let got =
        if c["interface"].getStr == "internal":
          signInternal(sk, msg, rnd)
        else:
          let ctx = bytes(c["context"].getStr)
          if rnd.isSome:
            signWithRandomness(sk, msg, ctx, rnd.get)
          else:
            signDeterministic(sk, msg, ctx)
      check got.isOk and got.get == want
      inc ran
    check ran > 0

  test "ACVP sigVer: every failure reason, pure and internal":
    check acvp["sigVer"].len == 28
    for c in acvp["sigVer"]:
      checkpoint "tcId " & $c["tcId"].getInt & ": " & c["reason"].getStr
      let pk = bytes(c["pk"].getStr)
      let msg = bytes(c["message"].getStr)
      let sig = bytes(c["signature"].getStr)
      let got =
        if c["interface"].getStr == "internal":
          verifyInternal(pk, msg, sig)
        else:
          verify(pk, msg, sig, bytes(c["context"].getStr))
      check got == c["testPassed"].getBool

  test "[PM §4.3] hedged signing with fresh randomness; a signature verifies only for its key, message and context":
    let (sk, pk) = generateKeyPair().get
    let (_, other) = generateKeyPair().get
    let msg = @[byte 1, 2, 3]
    let a = sign(sk, msg).get
    let b = sign(sk, msg).get
    check a.len == SignatureBytes and a != b
    check verify(pk, msg, a) and verify(pk, msg, b)
    check signDeterministic(sk, msg).get == signDeterministic(sk, msg).get
    check verify(pk, msg, signDeterministic(sk, msg).get)
    check not verify(other, msg, a)
    check not verify(pk, @[byte 1, 2, 4], a)
    check not verify(pk, msg, a, context = @[byte 0])
    var flipped = a
    flipped[^1] = flipped[^1] xor 1
    check not verify(pk, msg, flipped)

  test "[PKG-0446] key generation and hedged signing fail without randomness":
    proc broken(dest: var openArray[byte]): bool =
      false

    check generateKeyPair(broken).isErr
    let (sk, _) = generateKeyPair().get
    check sign(sk, [1'u8], random = broken).isErr

  test "[PM §4.3] no key or signature is truncated, padded or repaired":
    let (sk, pk) = generateKeyPair().get
    let sig = sign(sk, []).get
    check verify(pk, [], sig)
    check not verify(pk[0 ..< 47], [], sig)
    check not verify(@pk & @[byte 0], [], sig)
    check not verify(pk, [], sig[0 ..< SignatureBytes - 1])
    check not verify(pk, [], sig & @[byte 0])
    check sign(sk, [], newSeq[byte](MaxContextBytes + 1)).isErr
    check not verify(pk, [], sig, newSeq[byte](MaxContextBytes + 1))
