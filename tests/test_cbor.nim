import std/[json, random, strutils]
import unittest2
import ../src/logos_core/cbor
import ../src/logos_core/base/hex
import ../src/logos_core/crypto/blake3
import ./support/specdata

type Vector = object
  hex, expect, note, diag: string

proc vectors(): seq[Vector] =
  let root = parseJson(readRepoFile("tests/vectors/cbor/decode.json"))
  var output: seq[Vector]
  for v in root["vectors"]:
    output.add(
      Vector(
        hex: v["hex"].getStr,
        expect: v["expect"].getStr,
        note: v["note"].getStr,
        diag: v{"diag"}.getStr,
      )
    )
  output

proc classOf(r: Result[CborValue, CborError]): string =
  if r.isOk:
    return "ok"
  case r.error.kind
  of cekMalformed: "malformed"
  of cekNonDeterministic: "non-deterministic"
  of cekInvalidUtf8: "invalid-utf8"
  of cekTooDeep: "too-deep"

proc enc(v: CborValue): string =
  encodeCbor(v).toHex

suite "cbor: oracle vectors (tests/vectors/cbor/decode.json)":
  let all = vectors()

  test "[IFC-0408] [IFC-0417] [CDE-0136] [CDE-0137] every accepted item re-encodes to the same bytes":
    var n = 0
    for v in all:
      if v.expect != "ok":
        continue
      let r = decodeCbor(hexBytes(v.hex))
      check r.isOk
      if r.isOk:
        check enc(r.get) == v.hex
        if v.diag.len > 0:
          check toDiag(r.get) == v.diag
          let parsed = parseDiag(v.diag)
          check parsed.isOk and enc(parsed.get) == v.hex
        inc n
    check n > 70

  test "[IFC-0409] [IFC-0410] [IFC-0411] [IFC-0412] [IFC-0416] non-deterministic items are rejected as such":
    var n = 0
    for v in all:
      if v.expect == "non-deterministic":
        let got = classOf(decodeCbor(hexBytes(v.hex)))
        checkpoint v.hex & " (" & v.note & ")"
        check got == "non-deterministic"
        inc n
    check n >= 40

  test "items that are not well-formed are rejected as malformed (RFC 8949 App F)":
    for v in all:
      if v.expect == "malformed":
        checkpoint v.hex & " (" & v.note & ")"
        check classOf(decodeCbor(hexBytes(v.hex))) == "malformed"

  test "[IFC-0420] [IFC-0421] [IFC-0422] invalid UTF-8 is its own class and never yields text":
    for v in all:
      if v.expect == "invalid-utf8":
        let data = hexBytes(v.hex)
        checkpoint v.hex & " (" & v.note & ")"
        check classOf(decodeCbor(data)) == "invalid-utf8"
        var opts = defaultDecodeOptions()
        opts.allowInvalidUtf8 = true
        let kept = decodeCbor(data, opts)
        check kept.isOk
        if kept.isOk:
          check enc(kept.get) == v.hex
          let text =
            if kept.get.kind == ckText:
              kept.get
            else:
              kept.get.entries[0].key
          check text.kind == ckText and not text.validUtf8
          check text.getText.isNone

  test "[IMPL-DECISION G59] nesting is capped at 1024 containers":
    for v in all:
      if v.expect == "too-deep" or v.note.contains("nested"):
        checkpoint v.note
        check classOf(decodeCbor(hexBytes(v.hex))) == v.expect
    var opts = defaultDecodeOptions()
    opts.maxDepth = 2
    check classOf(decodeCbor(hexBytes("818100"), opts)) == "ok"
    check classOf(decodeCbor(hexBytes("81818100"), opts)) == "too-deep"
    check classOf(decodeCbor(hexBytes("8180"), opts)) == "ok"
    check classOf(decodeCbor(hexBytes("818180"), opts)) == "too-deep"

suite "cbor: encoder":
  test "[IFC-0410] [CDE-0138] heads use the shortest argument at every boundary":
    check enc(cbor(23'u64)) == "17"
    check enc(cbor(24'u64)) == "1818"
    check enc(cbor(255'u64)) == "18ff"
    check enc(cbor(256'u64)) == "190100"
    check enc(cbor(65535'u64)) == "19ffff"
    check enc(cbor(65536'u64)) == "1a00010000"
    check enc(cbor(0xffff_ffff'u64)) == "1affffffff"
    check enc(cbor(0x1_0000_0000'u64)) == "1b0000000100000000"
    check enc(cbor(high(uint64))) == "1bffffffffffffffff"
    check enc(cbor(-24)) == "37"
    check enc(cbor(-25)) == "3818"
    check enc(cbor(low(int64))) == "3b7fffffffffffffff"
    check enc(cborNint(high(uint64))) == "3bffffffffffffffff"
    check enc(cbor(newString(24))) == "7818" & "00".repeat(24)
    check enc(cborTag(24, cbor(0'u64))) == "d81800"

  test "[IFC-0401] [IFC-0409] [CDE-0141] [CDE-0142] map keys sort bytewise, not length first":
    check enc(cborMap((cbor(-1), cbor(15)), (cbor(100), cbor(0)))) == "a2186400200f"
    check enc(cborMap((cbor("b"), cbor(2)), (cbor("aa"), cbor(1)))) ==
      "a2616202626161" & "01"
    check enc(cborMap((cborArray(), cbor(1)), (cbor(1), cbor(2)))) ==
      "a2" & "0102" & "8001"

  test "[IFC-0402] the INTERFACE §4.2 space_info example orders keys used < quota < available":
    let v = cborMap(
      (cbor("available"), cbor(1073741824)),
      (cbor("quota"), cbor(10737418240'i64)),
      (cbor("used"), cbor(9663676416'i64)),
    )
    check enc(v) ==
      "a3" & "6475736564" & "1b0000000240000000" & "6571756f7461" & "1b0000000280000000" &
      "69617661696c61626c65" & "1a40000000"

  test "[IFC-0405] [IFC-0406] the INTERFACE §4.3 call and result examples":
    check enc(cborMap((cbor("cid"), cbor("bafy...")))) ==
      "a163636964" & "6762616679" & "2e2e2e"
    check enc(cborMap((cbor("exists"), cbor(true)))) == "a166657869737473f5"
    check enc(cborMap()) == "a0"

  test "[IFC-0411] [IFC-0412] [CDE-0139] [CDE-0140] definite lengths only; duplicate keys are a bug":
    let nested =
      cborArray(cbor("x"), cborArray(cbor(@[1'u8])), cborMap((cbor(1), cborArray())))
    check enc(nested) == "836178814101a10180"
    expect AssertionDefect:
      discard encodeCbor(cborMap((cbor(1), cbor(1)), (cbor(1), cbor(2))))

  test "[IMPL-DECISION G38] [IFC-0413] floats are data-model values, encoded in the shortest width":
    check enc(cborFloat(0.0)) == "f90000"
    check enc(cborFloat(-0.0)) == "f98000"
    check enc(cborFloat(1.5)) == "f93e00"
    check enc(cborFloat(65504.0)) == "f97bff"
    check enc(cborFloat(100000.0)) == "fa47c35000"
    check enc(cborFloat(1.1)) == "fb3ff199999999999a"
    check enc(cborFloat(5.960464477539063e-8)) == "f90001"
    check enc(cborFloat(Inf)) == "f97c00"
    check enc(cborFloat(NegInf)) == "f9fc00"
    check enc(cborFloat(NaN)) == "f97e00"
    for f in [0.1, 1e300, 3.4028234663852886e38, -4.1, 1.401298464324817e-45]:
      let v = cborFloat(f)
      check toFloat64(v) == f
      let back = decodeCbor(encodeCbor(v))
      check back.isOk and back.get == v

suite "cbor: diagnostic notation and the spec's own blocks":
  test "[CDE-0198] [CDE-0199] [CDE-0137] cdCDDLe App A: the diagnostic block encodes to the 522 normative bytes":
    let parsed = parseDiag(mirror("CDE/app-a.schema.diag"))
    check parsed.isOk
    let want = mirrorHex("CDE/app-a.cbor.hex")
    check want.len == parseInt(pin("cde-app-a-length"))
    check encodeCbor(parsed.get) == want
    let decoded = decodeCbor(want)
    check decoded.isOk and decoded.get == parsed.get

  test "[CMT-0190] HASH App A field 4 is the COMMITMENT App A schema object":
    let input = mirrorHex("HSH/app-a.hash-input.hex")
    check input.len == parseInt(pin("hsh-app-a-input-length"))
    let decoded = decodeCbor(input)
    check decoded.isOk
    let schema = parseDiag(mirror("CMT/app-a.schema.diag"))
    check schema.isOk
    check decoded.get.lookup(4'u64).get == schema.get
    check decoded.get.lookup(1'u64).get.getText.get == pin("hash-profile-id")
    check decoded.get.lookup(2'u64).get.getText.get == pin("hash-suite-id")
    check decoded.get.lookup(3'u64).get.getText.get == pin("commitment-model-id")
    check blake3(input).toHex == pin("hsh-app-a-root")

  test "diagnostic parser: escapes, negative bounds, tags and errors":
    check enc(parseDiag("\"\\u00fc\\ud800\\udd51\\n\"").get) ==
      "67" & "c3bcf0908591" & "0a"
    check enc(parseDiag("-18446744073709551616").get) == "3bffffffffffffffff"
    check enc(parseDiag("[1, [2, 3,], {\"a\": 24(h'00 ff'),},]").get) ==
      "83" & "01" & "820203" & "a16161d8184200ff"
    check parseDiag("18446744073709551616").isErr
    check parseDiag("[1 2]").isErr
    check parseDiag("h'abc'").isErr
    check parseDiag("\"\\ud800\"").isErr
    check parseDiag("{1: 2} 3").isErr

suite "cbor: fuzz smoke (fixed seed)":
  test "mutated inputs never crash; accepted ones re-encode exactly":
    var rng = initRand(0x10605)
    let seeds = block:
      var s: seq[seq[byte]]
      for v in vectors():
        if v.expect == "ok" and v.hex.len < 200:
          s.add(hexBytes(v.hex))
      s
    var accepted = 0
    for round in 0 ..< 20_000:
      var data = seeds[rng.rand(seeds.high)]
      for _ in 0 .. rng.rand(3):
        case rng.rand(3)
        of 0:
          if data.len > 0:
            data[rng.rand(data.high)] = byte(rng.rand(255))
        of 1:
          data.insert(byte(rng.rand(255)), rng.rand(data.len))
        of 2:
          if data.len > 0:
            data.delete(rng.rand(data.high))
        else:
          data.add(seeds[rng.rand(seeds.high)])
      let r = decodeCbor(data)
      if r.isOk:
        inc accepted
        check encodeCbor(r.get) == data
    check accepted > 0

  test "random values survive encode and decode":
    var rng = initRand(0xcb0)
    proc gen(depth: int): CborValue =
      let k =
        if depth > 4:
          rng.rand(4)
        else:
          rng.rand(8)
      case k
      of 0:
        cbor(rng.rand(high(int64)).uint64 * uint64(rng.rand(1) + 1))
      of 1:
        cbor(-rng.rand(high(int64)) - 1)
      of 2:
        var b = newSeq[byte](rng.rand(40))
        for x in b.mitems:
          x = byte(rng.rand(255))
        cbor(b)
      of 3:
        cbor($rng.rand(1_000_000) & "ü")
      of 4:
        cbor(rng.rand(1) == 1)
      of 5:
        var items: seq[CborValue]
        for _ in 0 ..< rng.rand(5):
          items.add(gen(depth + 1))
        cborArray(items)
      of 6:
        var m = CborValue(kind: ckMap)
        for i in 0 ..< rng.rand(5):
          m.entries.add((cbor("k" & $i), gen(depth + 1)))
        m
      of 7:
        cborTag(uint64(rng.rand(100_000)), gen(depth + 1))
      else:
        cborFloat(rng.rand(1e6) - 5e5)

    for _ in 0 ..< 2_000:
      let v = gen(0)
      let bytes = encodeCbor(v)
      let back = decodeCbor(bytes)
      check back.isOk
      if back.isOk:
        check back.get == v
        check encodeCbor(back.get) == bytes
