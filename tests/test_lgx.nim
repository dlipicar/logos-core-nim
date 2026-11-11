## PM §2, §3, §7.1, §8: LGX archives. Packages are written with writeLgx and
## opened with openLgx; malformed archives come from a USTAR builder in this file
## whose header fields can be set to anything.

import std/[algorithm, os, sequtils, strutils]
import unittest2
import ../src/logos_core/base/hex
import ../src/logos_core/[cbor, pins]
import ../src/logos_core/crypto/blake3
import ../src/logos_core/package/lgx
import zlib/zlib_api

# A package -------------------------------------------------------------------------

proc b(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

type Files = seq[(string, seq[byte])]

let linuxFiles: Files = @[
  ("data/alpha.cbor", encodeCbor(cborMap())),
  ("lib/libalpha.so", b("ALPHA for linux")),
  ("lib/libbeta.so", b("BETA for linux")),
  ("schema/alpha.cddl", b("alpha_config = { level: uint }\n")),
]
let darwinFiles: Files = @[
  ("data/alpha.cbor", encodeCbor(cborMap())),
  ("lib/libalpha.dylib", b("ALPHA for darwin")),
  ("schema/alpha.cddl", b("alpha_config = { level: uint }\n")),
]

proc content(files: Files, path: string): seq[byte] =
  for (p, d) in files:
    if p == path:
      return d
  @[]

proc artifact(id, kind, path: string, files: Files): CborValue =
  cborMap(
    (cbor("id"), cbor(id)),
    (cbor("kind"), cbor(kind)),
    (cbor("path"), cbor(path)),
    (cbor("hash"), cbor(blake3(files.content(path)))),
  )

proc manifestValue(): CborValue =
  let commitment = cborMap(
    (cbor("commitment_model"), cbor(CommitmentModelId)),
    (cbor("schema_root"), cbor(newSeq[byte](32))),
    (cbor("hash_profile"), cbor(HashProfileId)),
    (cbor("hash_suite"), cbor(HashSuiteId)),
  )
  cborMap(
    (cbor("package"), cbor("logos.example")),
    (cbor("version"), cbor("1.0.0")),
    (
      cbor("modules"),
      cborArray(
        cborMap(
          (cbor("module"), cbor("alpha_module")),
          (cbor("artifact"), cbor("alpha")),
          (
            cbor("configuration"),
            cborMap(
              (cbor("schema_artifact"), cbor("alpha-config")),
              (cbor("root"), cbor("alpha_config")),
              (cbor("schema_commitment"), commitment),
              (cbor("default_artifact"), cbor("alpha-defaults")),
            ),
          ),
        ),
        cborMap((cbor("module"), cbor("beta_module")), (cbor("artifact"), cbor("beta"))),
      ),
    ),
    (
      cbor("variants"),
      cborArray(
        cborMap(
          (cbor("id"), cbor("linux-x86_64")),
          (
            cbor("platform"),
            cborMap(
              (cbor("os"), cbor("linux")),
              (cbor("architecture"), cbor("x86_64")),
              (cbor("abi"), cbor("gnu")),
            ),
          ),
          (
            cbor("artifacts"),
            cborArray(
              artifact("alpha", "module-binary", "lib/libalpha.so", linuxFiles),
              artifact("alpha-config", "schema", "schema/alpha.cddl", linuxFiles),
              artifact("alpha-defaults", "data", "data/alpha.cbor", linuxFiles),
              artifact("beta", "module-binary", "lib/libbeta.so", linuxFiles),
            ),
          ),
        ),
        cborMap(
          (cbor("id"), cbor("darwin-aarch64")),
          (
            cbor("platform"),
            cborMap(
              (cbor("os"), cbor("darwin")), (cbor("architecture"), cbor("aarch64"))
            ),
          ),
          (
            cbor("artifacts"),
            cborArray(
              artifact("alpha", "module-binary", "lib/libalpha.dylib", darwinFiles),
              artifact("alpha-config", "schema", "schema/alpha.cddl", darwinFiles),
              artifact("alpha-defaults", "data", "data/alpha.cbor", darwinFiles),
            ),
          ),
        ),
      ),
    ),
  )

let key = keyFromSeed(
  block:
    var s: Seed
    for i in 0 ..< SeedLen:
      s[i] = byte(i * 3)
    s
)
let kid = b("lgx-test")
var trust: TrustInput
doAssert trust.addAnchor(kid, key.publicKey, ["logos.example"]).isOk

let linuxHost = Platform(os: "linux", architecture: "x86_64", abi: Opt.some("gnu"))
let darwinHost = Platform(os: "darwin", architecture: "aarch64")
let windowsHost = Platform(os: "windows", architecture: "x86_64", abi: Opt.some("msvc"))

proc signed(v: CborValue): (seq[byte], seq[byte]) =
  let m = decodeManifest(encodeCbor(v)).get
  (m.encoded, signManifest(m, kid, key).get)

proc pack(v = manifestValue(), linux = linuxFiles, darwin = darwinFiles): seq[byte] =
  let (cbor, cose) = signed(v)
  writeLgx(cbor, cose, @[("linux-x86_64", linux), ("darwin-aarch64", darwin)]).get

proc opened(
    data: seq[byte],
    host = linuxHost,
    limits = DefaultLgxLimits,
    rules = PathRules(), # exact comparison, whatever filesystem the tests run on
): string =
  let r = openLgx(data, trust, host, limits, rules)
  if r.isOk:
    "ok"
  else:
    checkpoint r.error.msg
    if existsEnv("LCN_TEST_TRACE"):
      echo "    ", r.error.msg
    $r.error.code

# A USTAR builder with every field settable ------------------------------------------

type Raw = object
  name, prefix: string
  typeflag: char
  mode, uid, gid, mtime: int
  uname, linkname, magic, version: string
  data: seq[byte]

proc raw(path: string, dir = false, data: seq[byte] = @[]): Raw =
  Raw(
    name:
      if dir:
        path & "/"
      else:
        path,
    typeflag: if dir: '5' else: '0',
    mode: if dir: 0o755 else: 0o644,
    magic: "ustar\0",
    version: "00",
    data: data,
  )

proc header(r: Raw): seq[byte] =
  var h = newSeq[byte](512)
  proc put(at: int, s: string) =
    for i, c in s:
      h[at + i] = byte(c)

  proc octal(at, width, v: int) =
    put(at, toOct(v, width - 1))

  put(0, r.name)
  octal(100, 8, r.mode)
  octal(108, 8, r.uid)
  octal(116, 8, r.gid)
  octal(124, 12, r.data.len)
  octal(136, 12, r.mtime)
  h[156] = byte(r.typeflag)
  put(157, r.linkname)
  put(257, r.magic)
  put(263, r.version)
  put(265, r.uname)
  put(345, r.prefix)
  put(148, "        ")
  var sum = 0
  for x in h:
    sum += int(x)
  put(148, toOct(sum, 6))
  h[154] = 0
  h

proc tar(entries: seq[Raw], tail = 1024): seq[byte] =
  for e in entries:
    result.add(header(e))
    result.add(e.data)
    result.setLen(result.len + (512 - e.data.len mod 512) mod 512)
  result.setLen(result.len + tail)

proc gz(t: seq[byte]): seq[byte] =
  gzipCompress(t).get

proc entriesOf(archive: seq[byte]): seq[Raw] =
  ## The conforming entries of a package, as editable raw headers.
  for e in readLgx(archive).get.entries:
    result.add(raw(e.path, e.kind == lekDir, e.data))

proc variedArchive(f: proc(es: var seq[Raw]), sort = false): seq[byte] =
  ## The package's entries changed by `f`; with `sort`, put back in path order
  ## so that only the rule under test can fail.
  var es = entriesOf(pack())
  f(es)
  if sort:
    es.sort(
      proc(a, b: Raw): int =
        cmp(
          a.prefix & a.name.strip(leading = false, chars = {'/'}),
          b.prefix & b.name.strip(leading = false, chars = {'/'}),
        )
    )
  gz(tar(es))

proc indexOf(es: seq[Raw], name: string): int =
  for i, e in es:
    if e.name == name:
      return i
  raiseAssert "no entry " & name

# Suites ----------------------------------------------------------------------------

suite "pkg.lgx: writing and opening packages (PM §3, §7.1)":
  let archive = pack()

  test "[PKG-0014] [PKG-0015] [PKG-0016] [PKG-0018] [PKG-0023] [PKG-0024] [PKG-0025] [PKG-0026] [PKG-0218] [PKG-0254] a written package opens, verified, on its platform":
    let p = openLgx(archive, trust, linuxHost)
    check p.isOk
    let pkg = p.get
    check pkg.variant.id == "linux-x86_64"
    check pkg.verified.signer.kid == kid
    check pkg.artifacts.mapIt(it.artifact.id) ==
      @["alpha", "alpha-config", "alpha-defaults", "beta"]
    check pkg.artifacts[1].data == linuxFiles.content("schema/alpha.cddl")
    check pkg.modules.mapIt(it.module) == @["alpha_module", "beta_module"]

  test "[PKG-0494] [PKG-0213] [PKG-0497] [PKG-0180] [PKG-0217] the first compatible variant is selected; modules without it are not":
    let p = openLgx(archive, trust, darwinHost).get
    check p.variant.id == "darwin-aarch64"
    check p.modules.mapIt(it.module) == @["alpha_module"]
    check opened(archive, windowsHost) == "incompatible-platform"
    check opened(archive, Platform(os: "linux", architecture: "x86_64")) ==
      "incompatible-platform" # the variant constrains the abi; this host has none
    check opened(
      archive, Platform(os: "linux", architecture: "aarch64", abi: Opt.some("gnu"))
    ) == "incompatible-platform"

  test "[PKG-0495] [IMPL-DECISION G73] defined platform values match byte for byte; others never match; an absent field matches anything":
    let c = PlatformConstraint(os: Opt.some("linux"))
    check c.compatible(linuxHost)
    check not c.compatible(Platform(os: "Linux", architecture: "x86_64"))
    check PlatformConstraint().compatible(windowsHost)
    # A value our profile does not define never matches, even itself.
    let plan9 = Platform(os: "plan9", architecture: "riscv64", abi: Opt.some("p9"))
    check not PlatformConstraint(os: Opt.some("plan9")).compatible(plan9)
    check not PlatformConstraint(architecture: Opt.some("riscv64")).compatible(plan9)
    check not PlatformConstraint(abi: Opt.some("p9")).compatible(plan9)
    check PlatformConstraint().compatible(plan9)
    let h = hostPlatform()
    check h.os in ["linux", "darwin", "windows", "android", "ios"]
    check h.architecture in ["x86_64", "aarch64"]

  test "[PKG-0205] [PKG-0206] [PKG-0207] [PKG-0208] [IMPL-DECISION G41] the writer's entries: byte order, zero ids and times, empty names, 0755 directories, 0644 files":
    let t = gunzip(archive, 1 shl 30).get
    var paths: seq[string]
    var pos = 0
    while pos + 512 <= t.len and t[pos] != 0:
      let h = t[pos ..< pos + 512]
      var name = ""
      for i in 0 ..< 100:
        if h[i] == 0:
          break
        name.add(char(h[i]))
      paths.add(name)
      let field = proc(at, width: int): string =
        for i in at ..< at + width:
          if h[i] != 0:
            result.add(char(h[i]))
      check field(108, 8) == "0000000"
      check field(116, 8) == "0000000"
      check field(136, 12) == "00000000000"
      check field(265, 32) == ""
      check field(297, 32) == ""
      check field(100, 8) == (if name.endsWith("/"): "0000755" else: "0000644")
      check field(257, 6) == "ustar"
      let size = parseOctInt(field(124, 12))
      pos += 512 + (size + 511) div 512 * 512
    check paths ==
      paths.sorted(
        proc(a, b: string): int =
          cmp(a.strip(chars = {'/'}), b.strip(chars = {'/'}))
      )
    check "variants/" in paths
    check "variants/linux-x86_64/lib/" in paths
    check paths[0 .. 1] == @["manifest.cbor", "manifest.cose"]

  test "[PKG-0209] the gzip header: no name, mtime zero, OS 255":
    check archive[0 .. 3] == @[0x1f'u8, 0x8b, 8, 0]
    check archive[4 .. 7] == @[0'u8, 0, 0, 0]
    check archive[9] == 255

  test "[PKG-0483] [PKG-0484] [IMPL-DECISION G40] long paths use the USTAR prefix; longer ones are refused":
    let deep = "d".repeat(90) & "/" & "f".repeat(60)
    var files = linuxFiles
    files.add(("res/" & deep, b("x")))
    var v = manifestValue()
    v.lookup("variants").get.items[0].lookup("artifacts").get.items.add(
      artifact("res", "resource", "res/" & deep, files)
    )
    let p = pack(v, linux = files)
    check opened(p) == "ok"
    var tooLong = linuxFiles
    tooLong.add(("res/" & "e".repeat(150) & "/" & "g".repeat(101), b("x")))
    let (cbor, cose) = signed(manifestValue())
    check writeLgx(
      cbor, cose, @[("linux-x86_64", tooLong), ("darwin-aarch64", darwinFiles)]
    ).isErr

suite "pkg.lgx: archive rules (PM §7.1, §8)":
  test "[PKG-0201] [PKG-0202] [PKG-0269] [PKG-0485] links, special files, pax and GNU long-name headers are invalid-package":
    for flag in ['1', '2', '3', '4', '6', '7', 'x', 'g', 'L']:
      let f = flag
      checkpoint "type " & $f
      check opened(
        variedArchive(
          proc(es: var seq[Raw]) =
            es[es.indexOf("variants/linux-x86_64/lib/libbeta.so")].typeflag = f
        )
      ) == "invalid-package"

  test "[PKG-0199] [PKG-0200] paths are relative UTF-8 NFC with no empty, ., .. segments, backslash or NUL":
    for p in [
      "/variants/x", "variants/linux-x86_64/./a", "variants/linux-x86_64/../a",
      "variants//a", "variants/linux-x86_64/a\\b", "variants/linux-x86_64/café",
      "variants/linux-x86_64/\xff",
    ]:
      let path = p
      checkpoint path.escape
      check opened(
        variedArchive(
          proc(es: var seq[Raw]) =
            es.add(raw(path, data = b("x"))),
          sort = true,
        )
      ) == "invalid-package"
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es[0].name = "manifest.cbor\0junk"
      )
    ) == "invalid-package"
    check checkArchivePath("variants/linux-x86_64/café").isOk

  test "[PKG-0201] [PKG-0205] duplicate paths and out-of-order entries are invalid-package":
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es.insert(es[0], 1)
      )
    ) == "invalid-package"
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          swap(es[0], es[1])
      )
    ) == "invalid-package"

  test "[PKG-0478] [PKG-0479] [PKG-0480] [IMPL-DECISION G41] directory entries: optional when descendants imply them, required for an empty variant, type 5 with size zero":
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es.keepItIf(it.typeflag != '5')
      )
    ) == "ok"
    # A variant with no descendant entry exists only through its directory entry.
    # Artifacts are never empty (PM §5 l.766), so only a variant whose files are
    # all missing has none: without the entry the archive is invalid-package,
    # even on the variant's own platform; with it, the missing artifacts decide.
    var bare = entriesOf(pack())
    bare.keepItIf(not (it.prefix & it.name).startsWith("variants/darwin-aarch64/"))
    check opened(gz(tar(bare))) == "invalid-package"
    check opened(gz(tar(bare)), darwinHost) == "invalid-package"
    var withDir = bare
    withDir.add(raw("variants/darwin-aarch64", dir = true))
    withDir.sort(
      proc(a, b: Raw): int =
        cmp(
          a.prefix & a.name.strip(leading = false, chars = {'/'}),
          b.prefix & b.name.strip(leading = false, chars = {'/'}),
        )
    )
    check opened(gz(tar(withDir))) == "invalid-package"
    check opened(gz(tar(withDir)), darwinHost) == "artifact-integrity-failed"
    # An explicit directory entry carries no data.
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          for e in es.mitems:
            if e.typeflag == '5':
              e.data = b("x")
              break
      )
    ) == "invalid-package"

  test "[PKG-0481] [PKG-0482] a directory path may end with one slash, removed before validation, duplicate detection and ordering; a file path may not":
    # Without the slash, a directory entry means the same.
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          for e in es.mitems:
            if e.typeflag == '5':
              e.name = e.name.strip(leading = false, chars = {'/'})
      )
    ) == "ok"
    # The same directory with and without the slash is a duplicate.
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          let i = es.indexOf("variants/linux-x86_64/")
          var plain = es[i]
          plain.name = "variants/linux-x86_64"
          es.insert(plain, i + 1)
      )
    ) == "invalid-package"
    # Only one slash is removed: a second leaves an empty segment.
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es[es.indexOf("variants/linux-x86_64/")].name = "variants/linux-x86_64//"
      )
    ) == "invalid-package"
    # A regular file named with a trailing slash.
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          let i = es.indexOf("variants/linux-x86_64/lib/libbeta.so")
          es[i].name = es[i].name & "/"
      )
    ) == "invalid-package"

  test "[PKG-0477] [PKG-0194] [PKG-0195] [PKG-0196] [PKG-0197] [PKG-0198] the root and variants/ structure":
    let cases = {
      "a root file": proc(es: var seq[Raw]) =
        es.add(raw("README", data = b("x"))),
      "a root manifest.json": proc(es: var seq[Raw]) =
        es.add(raw("manifest.json", data = b("""{"package": "logos.example"}"""))),
      "a root directory": proc(es: var seq[Raw]) =
        es.add(raw("docs", dir = true)),
      "a file in variants/": proc(es: var seq[Raw]) =
        es.add(raw("variants/notes.txt", data = b("x"))),
      "an extra variant directory": proc(es: var seq[Raw]) =
        es.add(raw("variants/windows-x86_64", dir = true)),
      "an uppercase variant directory": proc(es: var seq[Raw]) =
        es.add(raw("variants/Linux", dir = true)),
      "manifest.cbor as a directory": proc(es: var seq[Raw]) =
        es[0] = raw("manifest.cbor", dir = true),
      "variants as a file": proc(es: var seq[Raw]) =
        es[es.indexOf("variants/")] = raw("variants", data = b("x")),
    }
    for (name, f) in cases:
      checkpoint name
      check opened(variedArchive(f, sort = true)) == "invalid-package"
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es.keepItIf(not it.name.startsWith("variants/darwin-aarch64"))
      )
    ) == "invalid-package" # a manifest variant without its directory
    check isVariantId("linux-x86_64.v2_b")
    for bad in ["", ".", "..", "Linux", "a/b", "a b", "ünï"]:
      check not isVariantId(bad)

  test "[PKG-0206] [PKG-0207] [PKG-0208] header fields other than the conforming ones are invalid-package":
    let target = "variants/linux-x86_64/lib/libbeta.so"
    let cases = {
      "mode 0600": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].mode = 0o600,
      "mode 0755 on a file": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].mode = 0o755,
      "mode 0700 on a directory": proc(es: var seq[Raw]) =
        es[es.indexOf("variants/")].mode = 0o700,
      "uid 1000": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].uid = 1000,
      "gid 20": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].gid = 20,
      "mtime": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].mtime = 1_700_000_000,
      "uname": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].uname = "root",
      "linkname": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].linkname = "x",
      "GNU magic": proc(es: var seq[Raw]) =
        es[es.indexOf(target)].magic = "ustar "
        es[es.indexOf(target)].version = " \0",
    }
    for (name, f) in cases:
      checkpoint name
      check opened(variedArchive(f)) == "invalid-package"

  test "[PKG-0269] [PKG-0492] truncation, bad checksums, padding and trailing data are invalid-package":
    let good = tar(entriesOf(pack()))
    check opened(gz(good)) == "ok"
    check opened(gz(good[0 ..< good.len - 1024])) == "invalid-package" # no end blocks
    check opened(gz(good & newSeq[byte](9216))) == "ok" # zero record padding
    check opened(gz(good & newSeq[byte](512))) == "ok" # one more zero block
    check opened(gz(good & newSeq[byte](100))) == "invalid-package" # a partial block
    check opened(gz(good & newSeq[byte](1000))) == "invalid-package"
    var trailing = good
    trailing.add(b("junk"))
    check opened(gz(trailing)) == "invalid-package"
    var badSum = good
    badSum[0] = byte('n')
    check opened(gz(badSum)) == "invalid-package"
    var badPad = tar(entriesOf(pack()))
    badPad[512 + entriesOf(pack())[0].data.len] = 1 # inside manifest.cbor's padding
    check opened(gz(badPad)) == "invalid-package"

  test "[PKG-0209] [PKG-0490] [PKG-0491] [IMPL-DECISION G41] gzip headers and members: one member, CRC32 and ISIZE checked":
    let t = tar(entriesOf(pack()))
    let z = gz(t)
    check opened(z) == "ok"
    var named = z
    named[3] = 0x08
    check opened(named) == "invalid-package"
    var mtime = z
    mtime[4] = 1
    check opened(mtime) == "invalid-package"
    var os = z
    os[9] = 3
    check opened(os) == "invalid-package"
    check opened(z & gz(newSeq[byte](1024))) == "invalid-package" # a second member
    check opened(z & @[0'u8]) == "invalid-package"
    var crc = z
    crc[^8] = crc[^8] xor 1
    check opened(crc) == "invalid-package"
    var isize = z
    isize[^1] = isize[^1] xor 1
    check opened(isize) == "invalid-package"
    check opened(z[0 ..< z.len - 9]) == "invalid-package"
    # A comment and a header CRC are allowed.
    var withComment =
      z[0 .. 2] & @[0x12'u8] & z[4 .. 9] & b("built by a test") & @[0'u8]
    let hcrc = uint32(crc32(withComment)) and 0xffff
    withComment.add(byte(hcrc and 0xff))
    withComment.add(byte(hcrc shr 8))
    withComment.add(z[10 .. ^1])
    check opened(withComment) == "ok"

  test "[PKG-0210] [PKG-0211] [IMPL-DECISION G75] each limit rejects before installation":
    let p = pack()
    let t = gunzip(p, 1 shl 30).get
    let entries = readLgx(p).get.entries
    var l = DefaultLgxLimits
    l.compressed = p.len - 1
    check opened(p, limits = l) == "invalid-package"
    l = DefaultLgxLimits
    l.decompressed = t.len - 1
    check opened(p, limits = l) == "invalid-package"
    l = DefaultLgxLimits
    l.entries = entries.len - 1
    check opened(p, limits = l) == "invalid-package"
    l = DefaultLgxLimits
    l.entry = entries.mapIt(it.data.len).max - 1
    check opened(p, limits = l) == "invalid-package"
    l = DefaultLgxLimits
    l.extracted = linuxFiles.mapIt(it[1].len).foldl(a + b) - 1
    check opened(p, limits = l) == "artifact-integrity-failed"
    l.extracted += 1
    check opened(p, limits = l) == "ok"

suite "pkg.lgx: manifests, signatures and artifacts in the archive (PM §3, §7.1, §8)":
  test "[PKG-0023] [PKG-0255] [PKG-0025] [PKG-0277] a missing manifest is invalid-package; a missing signature fails verification":
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es.delete(0)
      )
    ) == "invalid-package"
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es.delete(1)
      )
    ) == "signature-verification-failed"

  test "[PKG-0018] [PKG-0068] [PKG-0074] a package is not opened without an accepted signature":
    var other: TrustInput
    check other.addAnchor(kid, keyFromSeed(default(Seed)).publicKey, ["logos.example"]).isOk
    check openLgx(pack(), other, linuxHost).error.code == pecSignature
    var notThisName: TrustInput
    check notThisName.addAnchor(kid, key.publicKey, ["logos.other"]).isOk
    check openLgx(pack(), notThisName, linuxHost).error.code == pecSignature

  test "[PKG-0214] every regular file in a variant is declared":
    var extra = linuxFiles
    extra.add(("lib/stray.so", b("x")))
    check opened(pack(linux = extra)) == "invalid-package"
    var extraDarwin = darwinFiles
    extraDarwin.add(("stray", b("x")))
    check opened(pack(darwin = extraDarwin)) == "invalid-package"
      # every variant, not only the selected one

  test "[PKG-0059] [PKG-0215] [PKG-0216] [PKG-0272] [PKG-0273] a declared artifact that is not a regular file":
    let missing = linuxFiles.filterIt(it[0] != "lib/libbeta.so")
    check opened(pack(linux = missing)) == "artifact-integrity-failed"
    let missingDarwin = darwinFiles.filterIt(it[0] != "schema/alpha.cddl")
    check opened(pack(darwin = missingDarwin)) == "invalid-package"
      # not the selected variant
    check opened(pack(darwin = missingDarwin), darwinHost) == "artifact-integrity-failed"

  test "[PKG-0058] [PKG-0059] [PKG-0218] [PKG-0276] [PKG-0067] an artifact whose bytes do not match its signed hash":
    var tampered = linuxFiles
    tampered[1] = ("lib/libalpha.so", b("ALPHA for linux, patched"))
    check opened(pack(linux = tampered)) == "artifact-integrity-failed"
    check opened(pack(linux = tampered), darwinHost) == "ok"
      # only the selected variant is used

  test "[PKG-0486] [IMPL-DECISION G73] paths that collide under the installation's rules":
    var v = manifestValue()
    var files = darwinFiles
    files.add(("res/Icon.png", b("1")))
    files.add(("res/icon.png", b("2")))
    let arts = v.lookup("variants").get.items[1].lookup("artifacts").get
    arts.items.add(artifact("icon-a", "resource", "res/Icon.png", files))
    arts.items.add(artifact("icon-b", "resource", "res/icon.png", files))
    let p = pack(v, darwin = files)
    let folding = PathRules(ignoreCase: true)
    let windows = PathRules(ignoreCase: true, windowsNames: true)
    check opened(p, darwinHost, rules = folding) == "invalid-package"
    check opened(p, darwinHost, rules = PathRules()) == "ok"
      # the rules follow the installation, not the target platform
    check checkInstallPaths(["res/Icon.png", "res/icon.png"], PathRules()).isOk
    check checkInstallPaths(["Lib/a", "lib/b"], folding).isErr
    check checkInstallPaths(["lib/con.txt"], windows).isErr
    check checkInstallPaths(["lib/a."], windows).isErr
    check checkInstallPaths(["lib/a:b"], windows).isErr
    check checkInstallPaths(["lib/con.txt"], folding).isOk
    when defined(windows):
      check hostPathRules() == windows
    elif defined(macosx) or defined(ios):
      check hostPathRules() == folding
    else:
      check hostPathRules() == PathRules()
