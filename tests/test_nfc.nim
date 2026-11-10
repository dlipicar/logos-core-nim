## base/nfc.nim against Python's unicodedata (tests/vectors/nfc.json, written by
## oracle/gen_nfc_tables.py), plus UAX #15 cases written out here.

import std/[json, strutils]
import unittest2
import ../src/logos_core/base/nfc
import ./support/specdata

suite "base.nfc: Normalization Form C (UAX #15) for LGX paths":
  let doc = parseJson(readRepoFile("tests/vectors/nfc.json"))

  test "the tables and the vectors come from the same Unicode version":
    check doc["unicode"].getStr == UnicodeVersion

  test "toNfc and isNfc agree with unicodedata on every vector":
    check doc["vectors"].len > 900
    for v in doc["vectors"]:
      let s = v["in"].getStr
      checkpoint s.escape
      check toNfc(s).get == v["nfc"].getStr
      check isNfc(s) == v["is_nfc"].getBool

  test "composition, ordering, exclusions, singletons and Hangul":
    check toNfc("é").get == "é"
    check toNfc("ậ").get == "ậ" # reordered, then composed
    check toNfc("Å").get == "Å" # a singleton decomposes and stays decomposed
    check toNfc("क़").get == "क़" # a composition exclusion
    check toNfc("각").get == "각"
    check toNfc("x́").get == "x́" # nothing to compose with
    check isNfc("variants/linux-x86_64/lib/libfoo.so")
    check not isNfc("café")

  test "invalid UTF-8 is not NFC":
    check not isNfc("\xff")
    check not isNfc("\xed\xa0\x80") # a surrogate
    check not isNfc("\xc0\xaf") # an overlong encoding
    check toNfc("\xff").isErr
