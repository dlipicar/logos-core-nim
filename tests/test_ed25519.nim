## Ed25519 over BoringSSL with the G42 checks (G135): RFC 8032 / ed25519.cr.yp.to
## and Wycheproof vectors as shipped inside the pinned nim-boringssl, and the
## edge cases of tests/vectors/ed25519/edge.json with the oracle's verdicts.

import std/[compilesettings, json, os, strutils, tables]
import unittest2
import boringssl
import ../src/logos_core/crypto/ed25519
import ../src/logos_core/base/hex
import ./support/specdata

const boringsslRoot = block:
  ## The nim-boringssl package directory on the search path (nimble.paths in
  ## both the Nimble and the Nix builds).
  var found = ""
  for p in querySettingSeq(searchPaths):
    if fileExists(p / "boringssl.nim") and dirExists(p / "boringssl" / "crypto"):
      found = p
  doAssert found.len > 0, "nim-boringssl is not on the search path"
  found

proc depFile(rel: string): string =
  readFile(boringsslRoot / "boringssl" / rel)

proc bytes(s: string): seq[byte] =
  hexBytes(s)

proc arr[N: static int](s: seq[byte]): array[N, byte] =
  doAssert s.len == N
  var a: array[N, byte]
  for i in 0 ..< N:
    a[i] = s[i]
  a

proc rawVerify(pk, msg, sig: openArray[byte]): bool =
  ## BoringSSL's ED25519_verify alone, without the G42 checks.
  if pk.len != 32 or sig.len != 64:
    return false
  var
    a: array[32'i64, uint8]
    s: array[64'i64, uint8]
  for i in 0 ..< 32:
    a[i] = pk[i]
  for i in 0 ..< 64:
    s[i] = sig[i]
  let m =
    if msg.len == 0:
      nil
    else:
      cast[ptr uint8](unsafeAddr msg[0])
  ED25519_verify(m, csize_t(msg.len), s, a) == 1

suite "crypto.ed25519: ed25519.cr.yp.to sign.input and RFC 8032 §7.1":
  let entries = block:
    var all: seq[Table[string, string]]
    for chunk in depFile("crypto/curve25519/ed25519_tests.txt").split("\n\n"):
      var e = initTable[string, string]()
      for line in chunk.splitLines:
        if line.len == 0 or line.startsWith("#"):
          continue
        let i = line.find(':')
        e[line[0 ..< i]] = line[i + 1 .. ^1].strip
      if e.len > 0:
        all.add(e)
    all

  test "512 sign.input entries, starting with RFC 8032 §7.1 TEST 1-3, then TEST 1024 and TEST SHA(abc)":
    check entries.len == 514
    check entries[0]["PUB"] ==
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    check entries[2]["MESSAGE"] == "af82"
    check entries[512]["PUB"] ==
      "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e"
    check entries[513]["MESSAGE"].startsWith("ddaf35a193617aba")

  test "key derivation, signing and verification reproduce every entry":
    var failures = 0
    for e in entries:
      let
        seed = arr[32](bytes(e["PRIV"])[0 ..< 32])
        pk = arr[32](bytes(e["PUB"]))
        msg = bytes(e["MESSAGE"])
        sig = arr[64](bytes(e["SIG"]))
        k = keyFromSeed(seed)
      if k.publicKey != pk or k.sign(msg) != sig or not verify(pk, msg, sig):
        inc failures
        checkpoint "entry " & e["PUB"]
      var bad = sig
      bad[0] = bad[0] xor 1
      if verify(pk, msg, bad):
        inc failures
    check failures == 0

suite "crypto.ed25519: Wycheproof":
  type WCase = object
    pk, msg, sig: seq[byte]
    valid: bool
    tcId: string
    flags: string

  let cases = block:
    var all: seq[WCase]
    var pk: seq[byte]
    var cur: WCase
    for line in depFile("third_party/wycheproof_testvectors/ed25519_test.txt").splitLines:
      if line.startsWith("[publicKey.pk = "):
        pk = bytes(line["[publicKey.pk = ".len ..^ 2])
      elif line.startsWith("# tcId = "):
        cur = WCase(pk: pk, tcId: line["# tcId = ".len .. ^1])
      elif line.startsWith("msg = "):
        cur.msg = bytes(line["msg = ".len .. ^1])
      elif line.startsWith("result = "):
        cur.valid = line.endsWith("valid") and not line.endsWith("invalid")
      elif line.startsWith("sig = "):
        cur.sig = bytes(line["sig = ".len .. ^1])
      elif line.startsWith("flags = "):
        cur.flags = line["flags = ".len .. ^1]
        all.add(cur)
    all

  test "[IMPL-DECISION G135] every Wycheproof verdict is reproduced":
    check cases.len == 150
    var valid = 0
    for c in cases:
      checkpoint "tcId " & c.tcId & " (" & c.flags & ")"
      check verify(c.pk, c.msg, c.sig) == c.valid
      if c.valid:
        inc valid
    check valid == 88

suite "crypto.ed25519: edge cases against the oracle (G42)":
  let doc = parseJson(readRepoFile("tests/vectors/ed25519/edge.json"))

  test "[IMPL-DECISION G42] the small-order blocklist is the set the oracle derives from the curve":
    var want: seq[string]
    for e in doc["small_order"]:
      want.add(e.getStr)
    var have: seq[string]
    for e in SmallOrderEncodings:
      have.add(e.toHex)
    check have == want

  test "[IMPL-DECISION G42] verify gives the oracle's libsodium verdict on every case":
    check doc["cases"].len >= 40
    for c in doc["cases"]:
      checkpoint c["name"].getStr & ": " & c["why"].getStr
      check verify(
        bytes(c["pk"].getStr), bytes(c["msg"].getStr), bytes(c["sig"].getStr)
      ) == c["strict"].getBool

  test "[IMPL-DECISION G135] raw BoringSSL gives the oracle's lenient verdict, so the pre-checks are what reject small-order points":
    var differ = 0
    for c in doc["cases"]:
      checkpoint c["name"].getStr
      let
        pk = bytes(c["pk"].getStr)
        msg = bytes(c["msg"].getStr)
        sig = bytes(c["sig"].getStr)
      check rawVerify(pk, msg, sig) == c["lenient"].getBool
      if c["lenient"].getBool != c["strict"].getBool:
        inc differ
        check hasSmallOrder(pk) or hasSmallOrder(sig[0 ..< 32])
    check differ == 15

  test "signing reproduces the oracle's signatures":
    for c in doc["cases"]:
      if c.hasKey("seed"):
        checkpoint c["name"].getStr
        let k = keyFromSeed(arr[32](bytes(c["seed"].getStr)))
        check k.publicKey.toHex == c["pk"].getStr
        check k.sign(bytes(c["msg"].getStr)).toHex == c["sig"].getStr

  test "[IMPL-DECISION G42] S < L is checked before BoringSSL, and BoringSSL checks it too":
    var s = SmallOrderEncodings[0]
    check isCanonicalScalar(s)
    s =
      arr[32](bytes("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010"))
    check not isCanonicalScalar(s)
    s[0] = 0xec
    check isCanonicalScalar(s)
    for c in doc["cases"]:
      if c["name"].getStr in ["s-plus-l", "s-equals-l"]:
        check not rawVerify(
          bytes(c["pk"].getStr), bytes(c["msg"].getStr), bytes(c["sig"].getStr)
        )

  test "[IMPL-DECISION G42] point encodings: canonical iff y < p, sign bit ignored":
    var e: array[32, byte]
    for i in 0 ..< 32:
      e[i] = 0xff
    e[31] = 0x7f
    e[0] = 0xec
    check isCanonicalPoint(e)
    e[0] = 0xed
    check not isCanonicalPoint(e)
    e[31] = 0xff
    check not isCanonicalPoint(e)
    e[30] = 0xfe
    check isCanonicalPoint(e)

  test "[IMPL-DECISION G42] trust input refuses small-order and non-canonical keys":
    for e in SmallOrderEncodings:
      var signed = e
      signed[31] = signed[31] or 0x80
      check checkPublicKey(signed).isErr
      check checkPublicKey(e).isErr
    check checkPublicKey(SmallOrderEncodings[1]).error == kfSmallOrder
    var nc: array[32, byte]
    for i in 0 ..< 32:
      nc[i] = 0xff
    nc[31] = 0x7f
    nc[0] = 0xf0
    check checkPublicKey(nc).error == kfNonCanonical
    check checkPublicKey(newSeq[byte](31)).error == kfLength
    let k = keyFromSeed(arr[32](bytes(repeat("00", 32))))
    check checkPublicKey(k.publicKey).get == k.publicKey
