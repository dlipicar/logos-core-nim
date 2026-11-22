## Step 5-5-2b (DECISIONS G446, G29's note, G75's sixth row; plan §4.3a): the streaming LGX reader
## against the oracle, the in-memory reader it replaced (`support/lgxoracle.nim`). Each archive
## is read four ways (`checkReaders`): the oracle, `openLgx`, and `inspectLgx` over a file and over
## bytes; one that opens is then extracted from the file and its files compared with the oracle's
## bytes. The results must agree up to the four kinds of message G29's note allows
## (`Agreement`). The corpus: generated packages; archives mutated from a fixed seed; Fable's
## three additions (an oversize `manifest.cbor` behind each earlier fault, the extracted bound
## crossed in both directions, an input set over 8 MiB); the documents' total cap, the one refusal
## the oracle does not make, compared with the expected result. `test_lgx`'s last suite runs the
## same comparison on every archive `test_lgx` builds.
##
## **The full corpus** [IMPL]: by default the 180-file archive (`rich`) is sampled, since each
## cut that keeps `manifest.cose` costs four signature verifications. With
## `LCN_LGX_FULL_CORPUS=1` nothing is sampled: all three archives are cut at every 512-byte
## boundary of the tar stream and of the compressed stream, and at every trailer byte, and every
## entry of each is dropped, doubled and swapped and has each header field broken. It is run
## once in the final CI pass, orc-release on Linux, from the dev shell (a flake check does not see
## the caller's environment): `LCN_LGX_FULL_CORPUS=1 nim c -r --mm:orc -d:release
## tests/test_lgx_equiv.nim`. CONFORMANCE, "The streaming reader".

import std/[algorithm, atomics, os, random, sequtils, strutils, tables]
import unittest2
import zlib/zlib_api
import ../src/logos_core/crypto/[cose, slhdsa]
import ./support/[lgxcorpus, lgxoracle]

let scratch = getTempDir() / "lcn-test-lgx-equiv-" & $getCurrentProcessId()
createDir(scratch)

let full = getEnv("LCN_LGX_FULL_CORPUS") == "1" ## nothing sampled (above)
if full:
  echo "    LCN_LGX_FULL_CORPUS=1: the full corpus, nothing sampled"

var kinds = initCountTable[Agreement]()

proc agrees(
    archive: seq[byte], host = linuxHost, limits = DefaultLgxLimits, rules = PathRules()
): Agreement =
  ## The four readings agree; the kind of agreement, counted.
  let r = checkReaders(archive, trust, host, limits, rules, scratch)
  if r.isErr:
    checkpoint r.error
    fail()
    return agSame
  kinds.inc(r.get)
  r.get

proc streaming(
    archive: seq[byte], host = linuxHost, limits = DefaultLgxLimits
): Result[LgxPackage, PackageError] =
  inspectLgx(bytesSource(archive), trust, host, limits, PathRules())

proc oracle(
    archive: seq[byte], host = linuxHost, limits = DefaultLgxLimits
): Result[LgxPackage, PackageError] =
  oracleOpenLgx(archive, trust, host, limits, PathRules())

const CapMessage =
  "the selected variant's contract and configuration documents pass the documents-size limit"

# Building packages --------------------------------------------------------------------------

proc variantValue(
    id: string, platform: CborValue, files: Files, ids: seq[(string, string, string)]
): CborValue =
  ## A variant whose artifacts are `ids` (id, kind, path), in id order.
  var arts: seq[CborValue]
  for (aid, kind, path) in ids.sortedByIt(it[0]):
    arts.add(artifact(aid, kind, path, files))
  cborMap(
    (cbor("id"), cbor(id)),
    (cbor("platform"), platform),
    (cbor("artifacts"), cborArray(arts)),
  )

let windowsPlatform = cborMap(
  (cbor("os"), cbor("windows")),
  (cbor("architecture"), cbor("x86_64")),
  (cbor("abi"), cbor("msvc")),
)
let windowsBase: Files = @[
  ("data/alpha.cbor", encodeCbor(cborMap())),
  ("lib/alpha.dll", b("ALPHA for windows")),
  ("schema/alpha.cddl", b("alpha_config = { level: uint }\n")),
]

proc signedArchive(v: CborValue, variants: seq[(string, Files)]): seq[byte] =
  let (cbor, cose) = signed(v)
  writeLgx(cbor, cose, variants).get

proc withContracts(v: CborValue, files: var seq[Files]) =
  ## `contractPackage`'s documents and entries: every document in every variant, `everyEntry`'s
  ## contracts on alpha_module.
  for vi in 0 ..< files.len:
    for (id, text) in docs:
      files[vi].add(("schema/" & id & ".cddl", b(text)))
  for vi in 0 ..< files.len:
    let arts = v.lookup("variants").get.items[vi].lookup("artifacts").get
    for (id, _) in docs:
      arts.items.add(artifact(id, "schema", "schema/" & id & ".cddl", files[vi]))
    arts.items.sort(
      proc(a, b: CborValue): int =
        cmp(a.lookup("id").get.getText.get, b.lookup("id").get.getText.get)
    )
  var listed = everyEntry
  listed.sort(
    proc(a, b: Entry): int =
      cmpBytes(encodeCbor(a.commitment), encodeCbor(b.commitment))
  )
  var values: seq[CborValue]
  for e in listed:
    var fields =
      @[(cbor("commitment"), e.commitment), (cbor("schema_artifact"), cbor(e.schema))]
    if e.inputs.len > 0:
      fields.add((cbor("input_artifacts"), cborArray(e.inputs.mapIt(cbor(it)))))
    values.add(cborMap(fields))
  v.entries.add((cbor("contract_documents"), cborArray(values)))
  let d = v.lookup("modules").get.items[0]
  d.entries.add((cbor("primary_contract"), alphaNewC))
  d.entries.add((cbor("implements"), cborArray(byBytes(@[dialNewC]))))
  d.entries.add((cbor("extends"), cborArray(byBytes(@[alphaOldC, dialOldC]))))

proc generated(rng: var Rand, variants, count: int, contracts: bool): seq[byte] =
  ## One to three variants (linux, darwin, windows), `count` data files in nested directories in
  ## each, random sizes and bytes, and with `contracts` `contractPackage`'s documents.
  var v = manifestValue()
  var files = @[linuxFiles, darwinFiles]
  let vs = v.lookup("variants").get
  if variants == 1:
    vs.items.setLen(1)
    files.setLen(1)
  if variants == 3:
    files.add(windowsBase)
    vs.items.add(
      variantValue(
        "windows-x86_64",
        windowsPlatform,
        windowsBase,
        @[
          ("alpha", "module-binary", "lib/alpha.dll"),
          ("alpha-config", "schema", "schema/alpha.cddl"),
          ("alpha-defaults", "data", "data/alpha.cbor"),
        ],
      )
    )
  for vi in 0 ..< files.len:
    for i in 0 ..< count:
      var data = newSeq[byte](rng.rand(1500))
      for x in data.mitems:
        x = byte(rng.rand(255))
      files[vi].add(("d" & $(i mod 5) & "/e" & $(i mod 3) & "/f" & $i & ".bin", data))
    let arts = vs.items[vi].lookup("artifacts").get
    for i in 0 ..< count:
      let path = "d" & $(i mod 5) & "/e" & $(i mod 3) & "/f" & $i & ".bin"
      arts.items.add(artifact("f-" & align($i, 3, '0'), "data", path, files[vi]))
  if contracts:
    v.withContracts(files)
  var named: seq[(string, Files)]
  for vi in 0 ..< files.len:
    named.add((vs.items[vi].lookup("id").get.getText.get, files[vi]))
  signedArchive(v, named)

proc flipped(a: seq[byte], at: int): seq[byte] =
  result = a
  result[at] = result[at] xor 0x20

proc gzStored(t: seq[byte]): seq[byte] =
  ## A gzip member of stored deflate blocks: each tar byte appears once, in order, so a flip of
  ## one tar byte is a flip of one archive byte.
  result = @[0x1f'u8, 0x8b, 8, 0, 0, 0, 0, 0, 0, GzipOsUnknown]
  var zs: ZStream
  doAssert deflateInit2(
    zs, Z_NO_COMPRESSION, Z_DEFLATED, Z_RAW_DEFLATE, Z_MEM_8, Z_DEFAULT_STRATEGY
  ) == Z_OK
  var buf = newSeq[byte](int(deflateBound(zs, culong(t.len))) + 64)
  zs.next_in = cast[ptr uint8](unsafeAddr t[0])
  zs.avail_in = cuint(t.len)
  zs.next_out = addr buf[0]
  zs.avail_out = cuint(buf.len)
  doAssert deflate(zs, Z_FINISH) == Z_STREAM_END
  let n = int(zs.total_out)
  discard deflateEnd(zs)
  result.add(buf.toOpenArray(0, n - 1))
  let crc = uint32(crc32(t))
  for i in 0 .. 3:
    result.add(byte((crc shr (8 * i)) and 0xff))
  for i in 0 .. 3:
    result.add(byte((uint32(t.len) shr (8 * i)) and 0xff))

proc withCrc(gzipped, t: seq[byte]): seq[byte] =
  ## `gzipped` with its trailer's CRC-32 set to `t`'s.
  result = gzipped
  let crc = uint32(crc32(t))
  for i in 0 .. 3:
    result[result.len - 8 + i] = byte((crc shr (8 * i)) and 0xff)

proc locate(hay, needle: openArray[byte]): int =
  for i in 0 .. hay.len - needle.len:
    var j = 0
    while j < needle.len and hay[i + j] == needle[j]:
      inc j
    if j == needle.len:
      return i
  -1

proc coseWith(payload: seq[byte], signer = key, kidBytes = kid): seq[byte] =
  ## A COSE_Sign1 over `payload` under `kidBytes`, signed with `signer`.
  var (c, tbs) = unsignedCose(kidBytes, payload)
  c.signature = sign(signer, tbs).get
  encodeCoseSign1(c)

# Suites ----------------------------------------------------------------------------------------

suite "pkg.lgx streaming: equivalence with the in-memory reader (step 5-5-2b, plan §4.3a)":
  var rng = initRand(0x5525b)
  let base = pack()
  let rich = generated(rng, 3, 60, contracts = true)
  # Every entry kind `rich` has (three variants, nested directories, documents), with four files
  # in each variant: small enough to cut at every boundary, since each cut that keeps
  # `manifest.cose` costs four signature verifications.
  let small = generated(rng, 3, 4, contracts = true)

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] generated packages: one to three variants, 0 to 300 files, nested directories, documents and configurations":
    for (variants, count, contracts) in [
      (1, 0, false),
      (2, 1, true),
      (3, 7, false),
      (1, 40, true),
      (2, 120, false),
      (3, 300, true),
      (2, 3, false),
      (1, 60, true),
    ]:
      let a = generated(rng, variants, count, contracts)
      check agrees(a) == agSame
      for host in [darwinHost, windowsHost]:
        discard agrees(a, host)
    check agrees(rich) == agSame

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] truncations: the tar stream at every 512-byte boundary of two archives, the trailer at every byte, and random offsets":
    # `rich` too, and every compressed stream, with the full corpus.
    let cutAll =
      if full:
        @[base, small, rich]
      else:
        @[base, small]
    for a in cutAll:
      let t = gunzip(a, 1 shl 30).get
      for cut in countup(0, t.len - 1, 512):
        discard agrees(gzipCompress(t[0 ..< cut]).get)
    # The compressed stream: every 512 bytes of `base`, and the trailer's every byte of both.
    for a in (if full: cutAll else: @[base]):
      for cut in countup(0, a.len - 1, 512):
        discard agrees(a[0 ..< cut])
    for a in cutAll:
      for back in 1 .. 16:
        discard agrees(a[0 ..< a.len - back])
    for a in [base, small, rich]:
      let t = gunzip(a, 1 shl 30).get
      for _ in 0 ..< 16:
        discard agrees(gzipCompress(t[0 ..< rng.rand(t.len - 1)]).get)
        discard agrees(a[0 ..< rng.rand(a.len - 1)])

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] flipped bytes in the compressed stream, and in the tar stream recompressed":
    for a in [base, small, rich]:
      let t = gunzip(a, 1 shl 30).get
      for _ in 0 ..< 24:
        discard agrees(a.flipped(rng.rand(a.len - 1)))
        discard agrees(gzipCompress(t.flipped(rng.rand(t.len - 1))).get)

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] entries reordered, duplicated or dropped":
    for a in [base, small, rich]:
      let es = entriesOf(a)
      # Every entry of `base`; the first twelve of `small` (the manifest files, the
      # directories, the first files) and twelve more; twelve of `rich`. Every entry of each,
      # with the full corpus.
      var at = toSeq(0 ..< es.len)
      if full:
        discard
      elif a == small:
        at = toSeq(0 ..< min(es.len, 12)) & toSeq(0 ..< 12).mapIt(rng.rand(es.len - 1))
      elif a == rich:
        at = toSeq(0 ..< 12).mapIt(rng.rand(es.len - 1))
      for i in at:
        var dropped = es
        dropped.delete(i)
        discard agrees(gz(tar(dropped)))
        var doubled = es
        doubled.insert(es[i], i)
        discard agrees(gz(tar(doubled)))
        if i + 1 < es.len:
          var swapped = es
          swap(swapped[i], swapped[i + 1])
          discard agrees(gz(tar(swapped)))

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] headers with each field broken":
    proc broken(r: var Raw, k: int) =
      case k
      of 0:
        r.uid = 1
      of 1:
        r.gid = 1
      of 2:
        r.mtime = 1
      of 3:
        r.mode = 0o600
      of 4:
        r.mode = 0o777
      of 5:
        r.typeflag = '1'
      of 6:
        r.typeflag = '2'
      of 7:
        r.typeflag = 'x'
      of 8:
        r.typeflag = '3'
      of 9:
        r.typeflag = 'L'
      of 10:
        r.linkname = "elsewhere"
      of 11:
        r.uname = "root"
      of 12:
        r.magic = "ustax\0"
      of 13:
        r.version = "01"
      of 14:
        r.name = r.name & "/"
      else:
        r.prefix = "elsewhere"

    for a in [base, small, rich]:
      let es = entriesOf(a)
      # Every field of the first eight entries (the manifest files, the directories, the first
      # files) of the two smaller archives; one field of each later entry of `small`, in turn;
      # eight random pairs of `rich`. Every field of every entry of each, with the full corpus.
      var pairs: seq[(int, int)]
      if full:
        for i in 0 ..< es.len:
          for k in 0 .. 15:
            pairs.add((i, k))
      elif a == rich:
        for _ in 0 ..< 8:
          pairs.add((rng.rand(es.len - 1), rng.rand(15)))
      else:
        for i in 0 ..< min(es.len, 8):
          for k in 0 .. 15:
            pairs.add((i, k))
        if a == small:
          for i in 8 ..< es.len:
            pairs.add((i, i mod 16))
      for (i, k) in pairs:
        var changed = es
        changed[i].broken(k)
        discard agrees(gz(tar(changed)))
      # a checksum that does not match, and trailing bytes of each kind
      var t = gunzip(a, 1 shl 30).get
      t[148] = t[148] xor 1
      discard agrees(gzipCompress(t).get)
      discard agrees(a & @[0'u8])
      discard agrees(a & a)
      discard agrees(gzipCompress(gunzip(a, 1 shl 30).get & @[1'u8]).get)
      discard agrees(gzipCompress(gunzip(a, 1 shl 30).get & newSeq[byte](100)).get)

  test "[IMPL-DECISION G446] [IMPL-DECISION G75] each limit one below what an archive needs, and an entry over the entry-size limit":
    for a in [base, rich]:
      let t = gunzip(a, 1 shl 30).get
      let es = readLgx(a).get.entries
      let p = streaming(a).get
      var largest = 0
      for e in es:
        largest = max(largest, e.data.len)
      var extracted = 0'i64
      for s in p.artifacts:
        extracted += s.size
      var l = DefaultLgxLimits
      l.compressed = a.len - 1
      check agrees(a, limits = l) == agSame
      l = DefaultLgxLimits
      l.decompressed = t.len - 1
      check agrees(a, limits = l) == agSame
      l = DefaultLgxLimits
      l.entries = es.len - 1
      check agrees(a, limits = l) == agSame
      l = DefaultLgxLimits
      l.entry = largest - 1
      check agrees(a, limits = l) == agSame
      l = DefaultLgxLimits
      l.extracted = extracted - 1
      check agrees(a, limits = l) == agSame
      # documents: the oracle has no such limit, so the expected result
      var kept = 0'i64
      for _, d in p.documents:
        kept += d.len
      if kept > 0:
        l = DefaultLgxLimits
        l.documents = kept - 1
        let r = streaming(a, limits = l)
        check r.isErr and r.error.code == pecInvalidPackage and r.error.msg == CapMessage
        l.documents = kept
        check streaming(a, limits = l).isOk

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] a bad signature with each format fault: the format fault":
    let (mc, ms) = signed(manifestValue())
    let bad = writeLgx(
      mc,
      ms.flipped(ms.len - 100),
      @[("linux-x86_64", linuxFiles), ("darwin-aarch64", darwinFiles)],
    ).get
    check agrees(bad) == agSame
    check streaming(bad).error.code == pecSignature
    let t = gunzip(bad, 1 shl 30).get
    for archive in [
      bad[0 ..< bad.len - 3], # a truncated trailer
      bad & @[0'u8], # data after the member
      bad.flipped(bad.len - 6), # the CRC-32
      gzipCompress(t[0 ..< t.len - 700]).get, # a truncated tar
      gzipCompress(t.flipped(148)).get, # a header checksum
      gzipCompress(t & @[7'u8]).get, # data after the end blocks
    ]:
      discard agrees(archive)
      check streaming(archive).error.code == pecInvalidPackage

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] an oversize manifest.cbor behind each fault verifyPackage checks before it (Fable's check (a))":
    let m = decodeManifest(encodeCbor(manifestValue())).get
    let c = m.commitment.get
    var big = m.encoded
    big.setLen(MaxManifestBytes + 10)
    let (otherKey, _) = testKey(9)
    var otherProfile = claimValue(c)
    otherProfile.entries[0] = (cbor("profile"), cbor("logos.other_profile"))
    var unsupported = c
    unsupported.schemaRoot[0] = unsupported.schemaRoot[0] xor 1
    let goodCose = coseWith(claimPayload(c).get)
    let coses = [
      @[0xa0'u8], # not a COSE_Sign1
      coseWith(claimPayload(c).get, otherKey, b("unknown-kid")), # an unknown kid
      goodCose.flipped(goodCose.len - 50), # a bad signature
      coseWith(encodeCbor(otherProfile)), # a claim of another profile
      coseWith(encodeCbor(claimValue(unsupported))), # an unsupported manifest schema
      goodCose, # nothing before it: decodeManifest's size check
    ]
    var codes: seq[PackageErrorCode]
    for cose in coses:
      let a = writeLgx(
        big, cose, @[("linux-x86_64", linuxFiles), ("darwin-aarch64", darwinFiles)]
      ).get
      check agrees(a) == agSame
      codes.add(streaming(a).error.code)
    check codes ==
      @[
        pecSignature, pecSignature, pecSignature, pecSignature, pecUnsupportedManifest,
        pecInvalidPackage,
      ]
    check streaming(
      writeLgx(
        big, goodCose, @[("linux-x86_64", linuxFiles), ("darwin-aarch64", darwinFiles)]
      ).get
    ).error.msg == "the manifest is larger than 4 MiB"

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] an oversize manifest.cose: its size first (case 10)":
    let c = CoseSign1(
      protectedBytes: protectedHeader(b("unknown-kid")),
      kid: b("unknown-kid"),
      payload: newSeq[byte](MaxSignatureBytes),
      signature: newSeq[byte](16224),
    )
    let (mc, _) = signed(manifestValue())
    let a = writeLgx(
      mc,
      encodeCoseSign1(c),
      @[("linux-x86_64", linuxFiles), ("darwin-aarch64", darwinFiles)],
    ).get
    check agrees(a) == agSignatureSize
    check oracle(a).error.msg.startsWith("no accepted trust anchor has kid")

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] the extracted bound crossed in archive order, with a bad hash before and after the crossing (case 6, Fable's check (a))":
    # x0, x1, x2 in id order, and so in manifest order, at paths in the reverse order.
    let x = @[("x0", "p/c"), ("x1", "p/b"), ("x2", "p/a")]
    proc package(badAt: string): seq[byte] =
      var files = linuxFiles
      var signedFiles = linuxFiles
      for (id, path) in x:
        files.add((path, newSeq[byte](1000)))
        signedFiles.add(
          (path, (if id == badAt: @[1'u8] & newSeq[byte](999)
            else: newSeq[byte](1000)))
        )
      var v = manifestValue()
      let vs = v.lookup("variants").get
      vs.items.setLen(1)
      let arts = vs.items[0].lookup("artifacts").get
      for (id, path) in x:
        arts.items.add(artifact(id, "data", path, signedFiles))
      signedArchive(v, @[("linux-x86_64", files)])

    var total = 0'i64
    for (_, d) in linuxFiles:
      total += d.len
    total += 3000
    # Archive order: data/alpha.cbor, lib/libalpha.so, lib/libbeta.so, p/a (x2), p/b (x1),
    # p/c (x0), schema/alpha.cddl. Manifest order: alpha, alpha-config (schema/alpha.cddl),
    # alpha-defaults, beta, x0, x1, x2.
    var l = DefaultLgxLimits
    l.extracted = total - 1500
    # Crossed in archive order at p/b, so p/b, p/c and schema/alpha.cddl are not hashed; the
    # streaming reader names the bound at alpha-config, the second in manifest order, and the
    # oracle crosses it at x1.
    check agrees(package(""), limits = l) == agSame
    check agrees(package("x0"), limits = l) == agBound
      # the oracle names x0's hash, before x1
    check agrees(package("x2"), limits = l) == agSame # after x1: the bound, both
    l.extracted = total - 1
    # Crossed in archive order only at schema/alpha.cddl, and in manifest order at x2.
    check agrees(package("x2"), limits = l) == agSame # x2's total passes before its hash
    check agrees(package("x0"), limits = l) == agBound

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] a contract whose input documents sum past 8 MiB, each under 1 MiB (Fable's check (a))":
    var v = manifestValue()
    let vs = v.lookup("variants").get
    vs.items.setLen(1)
    var files = linuxFiles
    var inputs: seq[string]
    let comment = ("; " & "x".repeat(1000) & "\n").repeat(950)
    for k in 0 ..< 9:
      let text = "s" & $k & ".r = tstr\n" & comment # 950 KiB, cheap to parse
      let id = "c-s" & $k
      files.add(("schema/" & id & ".cddl", b(text)))
      inputs.add(id)
    let primary =
      "_module = \"alpha_module\"\n\nalpha.ping_request = {}\nalpha.ping_response = {}\n"
    files.add(("schema/c-primary.cddl", b(primary)))
    let arts = vs.items[0].lookup("artifacts").get
    for id in inputs & @["c-primary"]:
      arts.items.add(artifact(id, "schema", "schema/" & id & ".cddl", files))
    arts.items.sort(
      proc(a, b: CborValue): int =
        cmp(a.lookup("id").get.getText.get, b.lookup("id").get.getText.get)
    )
    v.entries.add(
      (
        cbor("contract_documents"),
        cborArray(
          cborMap(
            (cbor("commitment"), alphaNewC),
            (cbor("schema_artifact"), cbor("c-primary")),
            (cbor("input_artifacts"), cborArray(inputs.mapIt(cbor(it)))),
          )
        ),
      )
    )
    let a = signedArchive(v, @[("linux-x86_64", files)])
    check agrees(a) == agSame
    check streaming(a).error.msg.endsWith(
      "the input set is larger than 8 MiB (INTERFACE §5.3)"
    )

  test "[IMPL-DECISION G446] [IMPL-DECISION G29] an input document whose `_interface` comes after its first 8 MiB, and a supporting document that fails (case 9)":
    # The in-memory reader reads the role from the whole document, so it is an interface and
    # the supporting one is accepted first, and named. The streaming reader keeps 8 MiB and one
    # byte of it, with no role, so it is taken for a supporting schema and refused first.
    var v = manifestValue()
    let vs = v.lookup("variants").get
    vs.items.setLen(1)
    var files = linuxFiles
    let big = ("; " & "x".repeat(1000) & "\n").repeat(8900) & "_interface = \"dial\"\n"
    files.add(("schema/c-a-big.cddl", b(big)))
    files.add(("schema/c-b-bad.cddl", b("units.label = \n")))
    let primary =
      "_module = \"alpha_module\"\n\nalpha.ping_request = {}\nalpha.ping_response = {}\n"
    files.add(("schema/c-primary.cddl", b(primary)))
    let arts = vs.items[0].lookup("artifacts").get
    for id in ["c-a-big", "c-b-bad", "c-primary"]:
      arts.items.add(artifact(id, "schema", "schema/" & id & ".cddl", files))
    arts.items.sort(
      proc(a, b: CborValue): int =
        cmp(a.lookup("id").get.getText.get, b.lookup("id").get.getText.get)
    )
    v.entries.add(
      (
        cbor("contract_documents"),
        cborArray(
          cborMap(
            (cbor("commitment"), alphaNewC),
            (cbor("schema_artifact"), cbor("c-primary")),
            (cbor("input_artifacts"), cborArray(cbor("c-a-big"), cbor("c-b-bad"))),
          )
        ),
      )
    )
    let a = signedArchive(v, @[("linux-x86_64", files)])
    checkpoint oracle(a).error.msg
    checkpoint streaming(a).error.msg
    check "input c-b-bad" in oracle(a).error.msg
    check "input c-a-big" in streaming(a).error.msg
    check agrees(a) == agDocument

  test "[IMPL-DECISION G446] [IMPL-DECISION G75] the documents' total cap: past it invalid-package, after every earlier content fault":
    let p = streaming(rich).get
    var kept = 0'i64
    for _, d in p.documents:
      kept += d.len
    var l = DefaultLgxLimits
    l.documents = kept - 1
    check oracle(rich, limits = l).isOk # the oracle does not make this refusal
    let r = streaming(rich, limits = l)
    check r.error.code == pecInvalidPackage and r.error.msg == CapMessage
    # Each earlier content fault is still the result, in both readers.
    let (mc, ms) = signed(manifestValue())
    let badSignature = writeLgx(
      mc,
      ms.flipped(ms.len - 100),
      @[("linux-x86_64", linuxFiles), ("darwin-aarch64", darwinFiles)],
    ).get
    var extra = entriesOf(rich)
    extra.add(raw("variants/linux-x86_64/zz-undeclared", data = b("x")))
    extra.sort(
      proc(a, b: Raw): int =
        cmp(
          a.prefix & a.name.strip(leading = false, chars = {'/'}),
          b.prefix & b.name.strip(leading = false, chars = {'/'}),
        )
    )
    let undeclared = gz(tar(extra))
    var changed = entriesOf(rich)
    for e in changed.mitems:
      if e.name == "variants/linux-x86_64/lib/libalpha.so":
        e.data = b("ALPHA changed")
    let badHash = gz(tar(changed))
    var tiny = l
    tiny.documents = 1
    var small = tiny
    small.extracted = 100
    for (a, host, limits) in [
      (badSignature, linuxHost, tiny),
      (rich, Platform(os: "android", architecture: "aarch64"), tiny),
      (undeclared, linuxHost, tiny),
      (badHash, linuxHost, tiny),
      (rich, linuxHost, small),
    ]:
      let old = oracle(a, host, limits)
      let new = streaming(a, host, limits)
      check old.isErr and new.isErr
      check old.error.code == new.error.code and old.error.msg == new.error.msg
      check new.error.msg != CapMessage

  test "[IMPL-DECISION G446] [IMPL-DECISION G75] at the default 64 MiB: nine 8 MiB documents are refused, before they are parsed":
    var v = manifestValue()
    let vs = v.lookup("variants").get
    vs.items.setLen(1)
    var files = linuxFiles
    var inputs: seq[string]
    let filler = "units.label = tstr\n".repeat(8 * 1024 * 1024 div 19 + 1)
    for k in 0 ..< 9:
      let id = "c-big" & $k
      files.add(("schema/" & id & ".cddl", b(filler)))
      inputs.add(id)
    let arts = vs.items[0].lookup("artifacts").get
    for id in inputs:
      arts.items.add(artifact(id, "schema", "schema/" & id & ".cddl", files))
    arts.items.sort(
      proc(a, b: CborValue): int =
        cmp(a.lookup("id").get.getText.get, b.lookup("id").get.getText.get)
    )
    v.entries.add(
      (
        cbor("contract_documents"),
        cborArray(
          cborMap(
            (cbor("commitment"), alphaNewC),
            (cbor("schema_artifact"), cbor(inputs[0])),
            (cbor("input_artifacts"), cborArray(inputs[1 .. ^1].mapIt(cbor(it)))),
          )
        ),
      )
    )
    let a = signedArchive(v, @[("linux-x86_64", files)])
    let r = streaming(a)
    check r.isErr and r.error.code == pecInvalidPackage and r.error.msg == CapMessage

  test "the agreements seen":
    checkpoint $kinds
    if existsEnv("LCN_TEST_TRACE"):
      echo "    ", kinds
    check kinds[agSame] > 500
    check kinds[agFormat] > 0 and kinds[agBound] > 0 and kinds[agSignatureSize] > 0
    check kinds[agDocument] > 0

suite "pkg.lgx streaming: the extraction pass against a changed source (step 5-5-2b, plan §4.3a)":
  var rng = initRand(0x5525c)
  let stored = gzStored(gunzip(generated(rng, 2, 20, contracts = true), 1 shl 30).get)
  let t = gunzip(stored, 1 shl 30).get
  let path = scratch / "spool.lgx"

  proc judged(): LgxPackage =
    writeFile(path, stored)
    inspectLgx(fileSource(path), trust, linuxHost, DefaultLgxLimits, PathRules()).get

  proc extracted(p: LgxPackage, stop: LgxStop = nil): Result[void, LgxExtractError] =
    var sink = initMemorySink()
    extractLgx(fileSource(path), p, sink, stop)

  test "[IMPL-DECISION G446] the stored archive opens, and extracts to the oracle's bytes":
    check agrees(stored) == agSame
    let p = judged()
    var sink = initMemorySink()
    check extractLgx(fileSource(path), p, sink).isOk
    for a in oracle(stored).get.artifacts:
      check sink.files[a.artifact.path] == a.data

  test "[IMPL-DECISION G446] a selected file's byte changed, the CRC-32 kept right: its hash":
    let p = judged()
    let content = b("ALPHA for linux")
    let at = stored.locate(content)
    let tat = t.locate(content)
    check at > 0 and tat > 0
    writeFile(path, stored.flipped(at).withCrc(t.flipped(tat)))
    let r = extracted(p)
    check r.error.fault == xfDiffers
    check "does not match its hash" in r.error.detail

  test "[IMPL-DECISION G446] a byte changed in another variant, or in the trailer; the file truncated, replaced or a link":
    let p = judged()
    let other = stored.locate(b("ALPHA for darwin"))
    check other > 0
    for changed in [
      stored.flipped(other),
      stored.flipped(stored.len - 5),
      stored[0 ..< stored.len - 1],
      pack(),
    ]:
      writeFile(path, changed)
      check extracted(p).error.fault == xfDiffers
    when defined(posix):
      writeFile(scratch / "real.lgx", stored)
      removeFile(path)
      createSymlink(scratch / "real.lgx", path)
      check extracted(p).error.fault == xfDiffers
      check inspectLgx(fileSource(path), trust, linuxHost).error.code ==
        pecPackageUnavailable
      removeFile(path)
    createDir(path)
    check extracted(p).error.fault == xfDiffers
    removeDir(path)

  test "[IMPL-DECISION G446] a stop ends either pass; a sink that refuses a write":
    let p = judged()
    var flag: Atomic[bool]
    flag.store(true)
    check extracted(p, addr flag).error.fault == xfStopped
    check inspectLgx(fileSource(path), trust, linuxHost, stop = addr flag).error.code ==
      pecPackageUnavailable
    var sink = initMemorySink(failAfter = 10)
    check extractLgx(fileSource(path), p, sink).error.fault == xfSink

removeDir(scratch)
