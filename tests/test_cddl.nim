import std/[random, sequtils, strutils]
import unittest2
import ../src/logos_core/[cbor, cddl]
import ../src/logos_core/base/hex
import ./support/specdata

type Vector = object
  name, expect, input, diag, canonicalHex, errorClass, notes: string
  isSource: bool
  fields: seq[string]

proc text(v: CborValue, key: string): string =
  let x = v.lookup(key)
  if x.isSome: x.get.getText.get else: ""

proc vectors(): seq[Vector] =
  ## tests/vectors/cddl/vectors.cbor, written by oracle/gen_cddl_vectors.py [G16].
  let root = decodeCbor(readRepoFile("tests/vectors/cddl/vectors.cbor")).get
  var output: seq[Vector]
  for r in root.lookup("vectors").get.items:
    var v = Vector(
      name: r.text("name"),
      expect: r.text("expect"),
      diag: r.text("canonical-diagnostic"),
      canonicalHex: r.text("canonical-cbor-hex"),
      errorClass: r.text("error-class"),
      notes: r.text("notes"),
      isSource: r.lookup("input-cddl").isSome,
    )
    v.input =
      if v.isSource:
        r.text("input-cddl")
      else:
        r.text("input-cbor-hex")
    for (k, _) in r.entries:
      v.fields.add(k.getText.get)
    output.add(v)
  output

let all = vectors()

proc category(prefix: string): seq[Vector] =
  all.filterIt(it.name.startsWith(prefix & "-"))

proc run(v: Vector) =
  ## Source vectors go through parse, resolve, canonicalize and encode; CBOR
  ## vectors through the decoder/checker.
  checkpoint v.name & ": " & v.input.escape
  if v.isSource:
    let doc = parseCddl(v.input)
    if v.expect == "valid":
      check doc.isOk
      if doc.isOk:
        let bytes = encodeCddl(doc.get).get
        check bytes.toHex == v.canonicalHex
        check toDiag(toCbor(doc.get)) == v.diag
        check decodeCddl(bytes).isOk
      else:
        checkpoint $doc.error
    else:
      check doc.isErr
      if doc.isErr:
        checkpoint $doc.error
        check $doc.error.class == v.errorClass
  else:
    let doc = decodeCddl(hexBytes(v.input))
    if v.expect == "valid":
      check doc.isOk
      if doc.isOk:
        check encodeCddl(doc.get).get.toHex == v.input
        check toDiag(decodeCbor(hexBytes(v.input)).get) == v.diag
    else:
      check doc.isErr
      if doc.isErr:
        checkpoint $doc.error
        check doc.error.class == ecDecode

proc runAll(prefix: string, atLeast: int) =
  let vs = category(prefix)
  check vs.len >= atLeast
  for v in vs:
    run(v)

proc hexOf(name: string): string =
  for v in all:
    if v.name == name:
      return v.canonicalHex
  doAssert false, "no vector " & name

proc sourceHex(src: string, scope: openArray[string] = []): string =
  let doc = parseCddl(src, scope)
  if doc.isErr:
    "error " & $doc.error
  else:
    encodeCddl(doc.get).get.toHex

suite "cddl: App A (normative)":
  test "[CDE-0191] [CDE-0192] [CDE-0193] [CDE-0194] [CDE-0195] [CDE-0196] [CDE-0197] [CDE-0198] [CDE-0199] [CDE-0011] [CDE-0025] [CDE-0029] [CDE-0098] [CDE-0158] App A source canonicalizes to the 522 normative bytes":
    let doc = parseCddl(mirror("CDE/app-a.input.cddl"))
    check doc.isOk
    let want = mirrorHex("CDE/app-a.cbor.hex")
    check want.len == parseInt(pin("cde-app-a-length"))
    check toCbor(doc.get) == parseDiag(mirror("CDE/app-a.schema.diag")).get
    check encodeCddl(doc.get).get == want
    check doc.get.rules.mapIt(it.name) ==
      @[
        "_module", "storage.blob_hash", "storage.changed_event", "storage.cid",
        "storage.exists_request", "storage.exists_response", "storage.lookup_key",
      ]
    let back = decodeCddl(want)
    check back.isOk
    check encodeCddl(back.get).get == want

suite "cddl: self vectors (tests/vectors/cddl/vectors.cbor)":
  test "[IMPL-DECISION G16] [CDE-0169] [CDE-0170] [CDE-0171] [CDE-0172] [CDE-0173] [CDE-0174] every record has the §12 shape":
    const allowed = [
      "name", "input-cddl", "input-cbor-hex", "expect", "canonical-diagnostic",
      "canonical-cbor-hex", "error-class", "notes",
    ]
    check all.len > 200
    for v in all:
      checkpoint v.name
      check v.fields.allIt(it in allowed)
      check v.name.len > 0
      check ("input-cddl" in v.fields) != ("input-cbor-hex" in v.fields)
      case v.expect
      of "valid":
        check v.canonicalHex.len > 0 and v.canonicalHex == v.canonicalHex.toLowerAscii
        check "error-class" notin v.fields
      of "invalid":
        check v.errorClass in
          ["syntax", "unsupported", "resolution", "canonical", "decode"]
        check "canonical-cbor-hex" notin v.fields and
          "canonical-diagnostic" notin v.fields
      else:
        check false
    check all.mapIt(it.name).deduplicate.len == all.len

  test "[CDE-0175] [CDE-0176] [CDE-0177] [CDE-0178] [CDE-0179] [CDE-0180] [CDE-0181] [CDE-0182] [CDE-0183] [CDE-0184] [CDE-0185] [CDE-0186] the set covers every §12 category":
    let names = all.mapIt(it.name)
    for prefix in [
      "presentation-whitespace", "presentation-comments", "presentation-number",
      "presentation-text", "presentation-bytes", "rule-order", "names", "choice-order",
      "reference",
    ]:
      checkpoint prefix
      check names.anyIt(it.startsWith(prefix))
    # one vector per unsupported category of §5.1
    for prefix in [
      "unsupported-group-rule", "unsupported-generic-rule",
      "unsupported-generic-application", "unsupported-rule-extension",
      "unsupported-group-choice", "unsupported-socket", "unsupported-unwrap",
      "unsupported-enumeration", "unsupported-tag", "unsupported-major-type",
      "unsupported-any-item", "unsupported-cut", "unsupported-arrow-key",
      "unsupported-text-key", "unsupported-occurrence", "unsupported-exclusive-range",
      "unsupported-control", "unsupported-float",
    ]:
      checkpoint prefix
      check names.anyIt(it.startsWith(prefix))
    for name in [
      "syntax-empty", "decode-empty-document", "decode-empty-choice",
      "decode-one-alternative-choice", "resolution-duplicate-rule",
      "decode-duplicate-rule", "decode-reference-name-digit",
      "decode-literal-uint-negative", "canonical-range-reversed",
      "decode-range-reversed", "decode-occurrence-upper-two", "decode-node-kind-2",
      "decode-unknown-field-rule", "decode-rules-out-of-order",
      "decode-map-members-out-of-order", "decode-cbor-non-shortest-key",
      "decode-cbor-indefinite-array",
    ]:
      checkpoint name
      check name in names

  test "[CDE-0004] [CDE-0017] [CDE-0018] [CDE-0019] [CDE-0020] [CDE-0021] [CDE-0022] [CDE-0059] [CDE-0060] [CDE-0061] [CDE-0153] [CDE-0157] [IMPL-DECISION G11] presentation does not change the model":
    runAll("presentation", 30)
    for group in [
      @[
        "presentation-whitespace-compact", "presentation-whitespace-spread",
        "presentation-whitespace-crlf", "presentation-whitespace-no-final-newline",
        "presentation-comments",
      ],
      @[
        "presentation-number-decimal", "presentation-number-hex",
        "presentation-number-hex-upper", "presentation-number-binary",
      ],
      @["presentation-text-plain", "presentation-text-escaped"],
      @[
        "presentation-bytes-hex", "presentation-bytes-hex-spaced",
        "presentation-bytes-hex-multiline", "presentation-bytes-base64",
        "presentation-bytes-base64-unpadded",
      ],
      @["presentation-bytes-quoted", "presentation-bytes-quoted-as-hex"],
      @["presentation-control-tight", "presentation-control-spaced"],
    ]:
      checkpoint $group
      check group.mapIt(hexOf(it)).deduplicate.len == 1

  test "[CDE-0023] [CDE-0024] [CDE-0069] [CDE-0177] top-level rule order is not an identity input":
    runAll("rule-order", 3)
    check hexOf("rule-order-sorted") == hexOf("rule-order-reversed")
    let src = "c = uint\nb = [* c]\na = {x: b, ? y: c}\nd = a / b\n"
    let once = sourceHex(src)
    for i in 0 ..< 20:
      var lines = src.strip.splitLines
      var rng = initRand(i)
      rng.shuffle(lines)
      check sourceHex(lines.join("\n") & "\n") == once

  test "[CDE-0038] [CDE-0062] [CDE-0063] [CDE-0067] [CDE-0154] [CDE-0178] distinct bound names stay distinct":
    runAll("names", 2)
    check sourceHex("a = uint\n") != sourceHex("b = uint\n")
    check sourceHex("a = 0..1\n") != sourceHex("a = 0 / 1\n")

  test "[CDE-0035] [CDE-0050] [CDE-0072] [CDE-0073] [CDE-0089] [CDE-0092] [CDE-0093] [CDE-0179] choices keep their order and flatten":
    runAll("choice", 5)
    check hexOf("choice-order-first") != hexOf("choice-order-second")

  test "[CDE-0040] [CDE-0041] [CDE-0044] [CDE-0075] [CDE-0076] [CDE-0077] [CDE-0083] [CDE-0155] [CDE-0180] references stay references, including cycles":
    runAll("reference", 4)

  test "[CDE-0005] [CDE-0042] [CDE-0150] [CDE-0030] [CDE-0031] [CDE-0032] [CDE-0033] [CDE-0034] [CDE-0036] [CDE-0037] [CDE-0039] [CDE-0043] [CDE-0045] [CDE-0046] [CDE-0047] [CDE-0048] [CDE-0049] [CDE-0051] [CDE-0052] [CDE-0053] [CDE-0070] [CDE-0081] [CDE-0082] [CDE-0084] [CDE-0085] [CDE-0086] [CDE-0087] [CDE-0088] [CDE-0090] [CDE-0091] [CDE-0095] [CDE-0096] [CDE-0151] [CDE-0156] every supported construct maps as §7.4 says":
    runAll("construct", 20)

  test "[CDE-0012] [CDE-0015] [CDE-0016] [CDE-0152] [CDE-0181] [CDE-0188] [IMPL-DECISION G10] [IMPL-DECISION G12] constructs outside §5.1 are rejected as unsupported":
    runAll("unsupported", 50)
    check category("unsupported").anyIt(it.notes == "G10")
    check category("unsupported").anyIt(it.notes == "G12")

  test "[CDE-0012] text that is not RFC 8610 CDDL is a syntax error":
    runAll("syntax", 20)

  test "[CDE-0054] [CDE-0055] [CDE-0056] [CDE-0057] [CDE-0183] names must resolve, be unique and not redefine the prelude":
    runAll("resolution", 6)

  test "[CDE-0094] [CDE-0128] [CDE-0129] canonicalization rejects reversed ranges, duplicate keys and invalid .size":
    runAll("canonical", 6)

  test "[CDE-0100] [CDE-0102] [CDE-0103] [CDE-0105] [CDE-0106] [CDE-0107] [CDE-0108] [CDE-0109] [CDE-0110] [CDE-0111] [CDE-0112] [CDE-0113] [CDE-0114] [CDE-0115] [CDE-0116] [CDE-0117] [CDE-0118] [CDE-0119] [CDE-0120] [CDE-0124] [CDE-0125] [CDE-0126] [CDE-0130] [CDE-0131] [CDE-0132] [CDE-0133] [CDE-0167] the decoder accepts and exposes canonical models":
    for v in category("decode"):
      if v.expect == "valid":
        run(v)
    check category("decode").countIt(it.expect == "valid") >= 3

  test "[CDE-0099] [CDE-0101] [CDE-0104] [CDE-0121] [CDE-0122] [CDE-0123] [CDE-0127] [CDE-0144] [CDE-0145] [CDE-0146] [CDE-0147] [CDE-0148] [CDE-0163] [CDE-0164] [CDE-0165] [CDE-0166] [CDE-0182] [CDE-0184] [CDE-0185] [CDE-0186] [CDE-0189] [IMPL-DECISION G13] the decoder rejects everything else":
    var n = 0
    for v in category("decode"):
      if v.expect == "invalid":
        run(v)
        inc n
    check n > 70
    check category("decode").anyIt(it.notes == "G13")

suite "cddl: stages, scope and the encoder":
  test "[CDE-0013] [CDE-0014] errors are reported by stage: parse, then resolution, then canonical":
    proc classOf(src: string): string =
      let r = parseCddl(src)
      if r.isOk:
        "ok"
      else:
        $r.error.class

    check classOf("a = undefined_name\nb = [+ uint]\n") == "unsupported"
    check classOf("a = 10..1\nb = undefined_name\n") == "resolution"
    check classOf("a = [+ uint]\nb = (\n") == "unsupported"
    check classOf("a = (\nb = [+ uint]\n") == "syntax"
    check classOf("a = int\nb = c\n") == "unsupported"
    check classOf("a = c\nb = int\n") == "resolution"
    let e = parseCddl("a = uint\n\nb = [\n  uint,\n  + tstr]\n").error
    check e.class == ecUnsupported and e.line == 5 and e.col == 3

  test "[IMPL-DECISION G14] names from an external scope stay references":
    let scope = ["logos.error", "logos.page"]
    let alone = CddlDocument(
      rules: @[Rule(name: "a", typ: CddlType(kind: tkReference, name: "logos.error"))]
    )
    check sourceHex("a = logos.error\n", scope) == encodeCddl(alone).get.toHex
    let doc = parseCddl("a = {e: logos.error, ? p: logos.page}\n", scope)
    check doc.isOk
    check doc.get.rules.len == 1
    let members = doc.get.rules[0].typ.members
    check members[0].typ.kind == tkReference and members[0].typ.name == "logos.error"
    check members[1].typ.kind == tkReference and members[1].typ.name == "logos.page"
    check parseCddl("a = logos.error\n").error.class == ecResolution
    check parseCddl("logos.error = uint\n", scope).error.class == ecResolution
    check parseCddl("a = uint\n", ["1bad"]).error.class == ecResolution
    check parseCddl("a = uint\n", ["int"]).error.class == ecResolution

  test "[CDE-0159] [CDE-0160] [CDE-0161] [CDE-0162] the encoder refuses models that break §8":
    let
      u = CddlType(kind: tkPrimitive, primitive: pUint)
      t = CddlType(kind: tkPrimitive, primitive: pTstr)
    proc docOf(rules: varargs[Rule]): CddlDocument =
      CddlDocument(rules: @rules)

    proc lit(l: Literal): CddlType =
      CddlType(kind: tkLiteral, literal: l)

    let good = docOf(Rule(name: "a", typ: u), Rule(name: "b", typ: t))
    check encodeCddl(good).get == encodeCddl(good).get
    for bad in [
      docOf(),
      docOf(Rule(name: "b", typ: u), Rule(name: "a", typ: t)),
      docOf(Rule(name: "a", typ: u), Rule(name: "a", typ: t)),
      docOf(Rule(name: "uint", typ: u)),
      docOf(Rule(name: "a-", typ: u)),
      docOf(Rule(name: "a", typ: CddlType(kind: tkReference, name: "tstr"))),
      docOf(Rule(name: "a", typ: CddlType(kind: tkChoice, alternatives: @[u]))),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(
            kind: tkChoice,
            alternatives: @[CddlType(kind: tkChoice, alternatives: @[u, t]), u],
          ),
        )
      ),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(
            kind: tkMap,
            members:
              @[Member(key: Opt.some("b"), typ: u), Member(key: Opt.some("a"), typ: u)],
          ),
        )
      ),
      docOf(Rule(name: "a", typ: CddlType(kind: tkMap, members: @[Member(typ: u)]))),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(kind: tkArray, members: @[Member(key: Opt.some("k"), typ: u)]),
        )
      ),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(
            kind: tkArray,
            members: @[Member(typ: u, occurrence: occUnbounded), Member(typ: t)],
          ),
        )
      ),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(kind: tkRange, low: uintLiteral(3), high: uintLiteral(3)),
        )
      ),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(kind: tkRange, low: textLiteral("a"), high: textLiteral("b")),
        )
      ),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(kind: tkSize, target: pBool, controller: lit(uintLiteral(1))),
        )
      ),
      docOf(
        Rule(
          name: "a",
          typ: CddlType(kind: tkSize, target: pTstr, controller: lit(nintLiteral(0))),
        )
      ),
      docOf(Rule(name: "a", typ: CddlType(kind: tkSize, target: pTstr, controller: u))),
    ]:
      check encodeCddl(bad).isErr

  test "source that is not UTF-8, and nesting limits":
    for src in [
      "a = \"\xff\"\n", "a = '\xc3('\n", "; \xe2\x82\n a = uint\n", "a = uint\xa0\n"
    ]:
      checkpoint src.escape
      check parseCddl(src).error.class == ecSyntax
    check parseCddl(
      "a = " & "[".repeat(MaxNesting - 1) & "uint" & "]".repeat(MaxNesting - 1)
    ).isOk
    check parseCddl("a = " & "[".repeat(MaxNesting) & "uint" & "]".repeat(MaxNesting)).error.class ==
      ecUnsupported
    check parseCddl("a = " & "(".repeat(MaxNesting) & "uint" & ")".repeat(MaxNesting)).error.class ==
      ecUnsupported
    let deep = decodeCddl(
      encodeCbor(
        parseDiag(
          "{0: 0, 1: [{0: 1, 1: \"a\", 3: " &
            "{0: 7, 1: {0: 9, 1: [{0: 10, 2: ".repeat(200) & "{0: 5, 1: \"uint\"}" &
            "}]}}".repeat(200) & "}], 2: \"cdcddle\"}"
        ).get
      )
    )
    check deep.isOk

suite "cddl: fuzz smoke (fixed seed)":
  test "mutated App A source never crashes; accepted models round-trip":
    var rng = initRand(0xcdd1)
    let src = mirror("CDE/app-a.input.cddl")
    const alphabet = " \n;=/[]{}(),:?*+.-0123456789abcdefhuxyz\"'<>~&#^$@_"
    var accepted = 0
    for _ in 0 ..< 5_000:
      var s = src
      for _ in 0 .. rng.rand(3):
        let at = rng.rand(s.len)
        case rng.rand(2)
        of 0:
          s.insert($alphabet[rng.rand(alphabet.high)], at)
        of 1:
          if at < s.len:
            s.delete(at .. at)
        else:
          if at < s.len:
            s[at] = alphabet[rng.rand(alphabet.high)]
      let doc = parseCddl(s)
      if doc.isOk:
        inc accepted
        let bytes = encodeCddl(doc.get)
        check bytes.isOk
        if bytes.isOk:
          let back = decodeCddl(bytes.get)
          check back.isOk and encodeCddl(back.get).get == bytes.get
    check accepted > 100

  test "mutated App A bytes never crash; accepted ones are canonical":
    var rng = initRand(0xcdd2)
    let seed = mirrorHex("CDE/app-a.cbor.hex")
    var accepted = 0
    for _ in 0 ..< 20_000:
      var data = seed
      for _ in 0 .. rng.rand(2):
        let at = rng.rand(data.high)
        case rng.rand(2)
        of 0:
          data[at] = byte(rng.rand(255))
        of 1:
          data[at] = data[at] xor byte(1 shl rng.rand(7))
        else:
          data.delete(at)
      let doc = decodeCddl(data)
      if doc.isOk:
        inc accepted
        check encodeCddl(doc.get).get == data
    check accepted > 0
