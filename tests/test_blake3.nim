## The official BLAKE3 test vectors (tests/vectors/blake3_test_vectors.json, from
## the BLAKE3 repository at the vendored commit; see tools/update-blake3.sh).

import std/json
import unittest2
import ../src/logos_core/crypto/blake3
import ../src/logos_core/base/hex
import ./support/specdata

proc input(n: int): seq[byte] =
  var data = newSeq[byte](n)
  for i in 0 ..< n:
    data[i] = byte(i mod 251)
  data

proc toBytes(s: string): seq[byte] =
  var b = newSeq[byte](s.len)
  for i, c in s:
    b[i] = byte(c)
  b

suite "blake3: official test vectors":
  let root = parseJson(readRepoFile("tests/vectors/blake3_test_vectors.json"))
  let key = block:
    var k: array[Blake3KeyLen, byte]
    let s = root["key"].getStr
    doAssert s.len == Blake3KeyLen
    for i, c in s:
      k[i] = byte(c)
    k
  let context = root["context_string"].getStr.toBytes

  test "the vendored C library is the pinned version":
    check blake3Version() == "1.8.7"

  test "hash, keyed_hash and derive_key, 32-byte and extended output":
    check root["cases"].len == 35
    for c in root["cases"]:
      let n = c["input_len"].getInt
      let data = input(n)
      checkpoint "input_len " & $n
      for (mode, field) in [(0, "hash"), (1, "keyed_hash"), (2, "derive_key")]:
        let want = c[field].getStr
        var h: Blake3Hasher
        case mode
        of 0:
          h.init()
        of 1:
          h.initKeyed(key)
        else:
          h.initDeriveKey(context)
        h.update(data)
        var extended = newSeq[byte](want.len div 2)
        var copy = h
        copy.finish(extended)
        check extended.toHex == want
        check h.finish().toHex == want[0 ..< 64]
      check blake3(data).toHex == c["hash"].getStr[0 ..< 64]

  test "incremental updates match one-shot hashing":
    let data = input(31_744)
    for step in [1, 63, 64, 65, 1023, 1024, 1025, 8191]:
      var h: Blake3Hasher
      h.init()
      var pos = 0
      while pos < data.len:
        let last = min(pos + step, data.len)
        h.update(data.toOpenArray(pos, last - 1))
        pos = last
      check h.finish() == blake3(data)
