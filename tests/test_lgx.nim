## PM §2, §3, §7.1, §8: LGX archives. Packages are written with writeLgx and
## opened with openLgx; malformed archives come from a USTAR builder whose header
## fields can be set to anything. The builders are in `support/lgxcorpus.nim`
## (step 5-5-2b), which `test_lgx_equiv` shares; `gunzip` is the oracle's.

import std/[algorithm, os, sequtils, sets, strutils, tables]
import unittest2
import logos_sdk/base/hex
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import logos_sdk/iface/accept
from logos_sdk/iface/surface import schemaCommitment
import ../src/logos_core/package/lgx
import ./support/[lgxcorpus, lgxoracle]
import zlib/zlib_api

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

  test "[PKG-0478] [PKG-0480] [PKG-0194] [PKG-0588] [TXT-0464] [IMPL-DECISION G41] directory entries: optional when descendants imply them; one directory per variant; type 5 with size zero":
    check opened(
      variedArchive(
        proc(es: var seq[Raw]) =
          es.keepItIf(it.typeflag != '5')
      )
    ) == "ok"
    # A variant with no descendant entry has a directory only through its
    # directory entry. Artifacts are never empty (PM §5 l.766), so only a variant
    # whose files are all missing has none: without the entry there is no
    # directory for the variant (PM l.905: invalid-package, the first failure
    # detected, PM l.1067); with it, its missing files are an integrity failure
    # on any host (PM l.1098, M25).
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
    check opened(gz(tar(withDir))) == "artifact-integrity-failed"
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

  test "[PKG-0269] [IMPL-DECISION I125] a tar cut at any length, or with any header byte changed, is refused and never crashes":
    # A tar that ends inside an entry's padding: manifest.cbor's header, its 10 bytes and 5 of
    # its padding (527 bytes). The reader indexed past the end and raised an IndexDefect.
    let plain = gunzip(writeLgx(b("0123456789"), b("x"), @[]).get, 1 shl 30).get
    let cut527 = readLgx(gzipCompress(plain[0 ..< 527]).get)
    check cut527.isErr
    check cut527.error.msg == "an entry's data is truncated: manifest.cbor"
    # Every proper prefix of a small valid archive's tar, and of its gzip member.
    let small = writeLgx(
      b("0123456789"),
      b("x"),
      @[("linux-x86_64", @[("lib/a.so", b("abc")), ("data/b", newSeq[byte](700))])],
    ).get
    check readLgx(small).isOk
    let t = gunzip(small, 1 shl 30).get
    var accepted: seq[string]
    for cut in 0 ..< t.len:
      if readLgx(gzipCompress(t[0 ..< cut]).get).isOk:
        accepted.add("tar cut at " & $cut)
    for cut in 0 ..< small.len:
      if readLgx(small[0 ..< cut]).isOk:
        accepted.add("gzip cut at " & $cut)
    check accepted.len == 0
    checkpoint accepted.join(", ")
    # Each byte of each header changed, with its checksum left as it was and with it set
    # again, so the fields after the checksum are parsed too. Whatever the result, no crash.
    proc withSum(x: var seq[byte], at: int) =
      for i in at + 148 ..< at + 156:
        x[i] = byte(' ')
      var sum = 0
      for i in at ..< at + 512:
        sum += int(x[i])
      let digits = toOct(sum, 6)
      for i, c in digits:
        x[at + 148 + i] = byte(c)
      x[at + 154] = 0
      x[at + 155] = byte(' ')

    var headers: seq[int]
    var pos = 0
    while pos + 512 <= t.len and t[pos ..< pos + 512].anyIt(it != 0):
      headers.add(pos)
      var size = 0
      for i in pos + 124 ..< pos + 135:
        size = size * 8 + int(t[i] - byte('0'))
      pos += 512 + (size + 511) div 512 * 512
    check headers.len == 8 # the two manifest files, four directories and two files
    for at in headers:
      for off in 0 ..< 512:
        for value in [t[at + off] xor 0x01, 0xff'u8, byte('7')]:
          var x = t
          x[at + off] = value
          discard readLgx(gzipCompress(x).get)
          if off notin 148 ..< 156:
            x.withSum(at)
            discard readLgx(gzipCompress(x).get)

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
  test "[PKG-0587] [TXT-0470] [IMPL-DECISION G40] a manifest path that breaks the LGX path rules is invalid-package, in any variant":
    # M24 (PM l.1082 with l.913-921): a `.` segment, a name that is not NFC
    # ("e" and a combining acute accent), a name that fits no USTAR header.
    for bad in [
      "data/./alpha.cbor", "data/e\xCC\x81.cbor", "data/" & "x".repeat(120) & ".cbor"
    ]:
      for vi in 0 .. 1:
        let path = bad
        checkpoint path & " in variant " & $vi
        let v = manifestValue()
        let a = v.lookup("variants").get.items[vi].lookup("artifacts").get.items[2]
        for e in a.entries.mitems:
          if e.key.getText == Opt.some("path"):
            e.value = cbor(path)
        check opened(pack(v)) == "invalid-package"
        check opened(pack(v), darwinHost) == "invalid-package"

  test "[PKG-0023] [PKG-0255] [PKG-0025] [PKG-0277] [TXT-0562] a missing manifest is invalid-package; a missing signature fails verification":
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
    check other.addAnchor(kid, testKey(1)[1], ["logos.example"]).isOk
    check openLgx(pack(), other, linuxHost).error.code == pecSignature
    var notThisName: TrustInput
    check notThisName.addAnchor(kid, pub, ["logos.other"]).isOk
    check openLgx(pack(), notThisName, linuxHost).error.code == pecSignature

  test "[PKG-0214] every regular file in a variant is declared":
    var extra = linuxFiles
    extra.add(("lib/stray.so", b("x")))
    check opened(pack(linux = extra)) == "invalid-package"
    var extraDarwin = darwinFiles
    extraDarwin.add(("stray", b("x")))
    check opened(pack(darwin = extraDarwin)) == "invalid-package"
      # every variant, not only the selected one

  test "[PKG-0059] [PKG-0585] [PKG-0216] [PKG-0272] [PKG-0588] [TXT-0468] a declared artifact that is not a regular file, in any variant, is an integrity failure":
    let missing = linuxFiles.filterIt(it[0] != "lib/libbeta.so")
    check opened(pack(linux = missing)) == "artifact-integrity-failed"
    let missingDarwin = darwinFiles.filterIt(it[0] != "schema/alpha.cddl")
    check opened(pack(darwin = missingDarwin)) == "artifact-integrity-failed"
      # M25: not the selected variant (PM l.1098)
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

suite "pkg.lgx: contract documents and extensions (PM §4, §9)":
  test "[PKG-0579] [TXT-0457] each contract document constructs its commitment from the selected variant's documents":
    let p = contractPackage(everyEntry)
    check opened(p) == "ok"
    check opened(p, darwinHost) == "ok"
    let pkg = openLgx(p, trust, linuxHost, DefaultLgxLimits, PathRules()).get
    check pkg.contracts.mapIt(encodeCbor(schemaCommitment(it.primary.root))) ==
      byBytes(everyEntry.mapIt(it.commitment)).mapIt(encodeCbor(it))
    # The earlier concrete contract is built with the interface it selects.
    check pkg.contracts.anyIt(it.primary.source == alphaOld and it.interfaces.len == 1)
    # One byte changed in a supporting document (its hash updated with it).
    var changed = docs
    changed[^1] = ("c-units", "units.label = bstr\n")
    check opened(contractPackage(everyEntry, documents = changed)) == "invalid-package"

  test "[PKG-0579] [TXT-0457] a document that cannot be constructed, or an entry that is not a contract":
    var broken = docs
    broken[^1] = ("c-units", "units.label = \n")
    check opened(contractPackage(everyEntry, documents = broken)) == "invalid-package"
    # An unused input and a repeated one.
    let unused: Entry = (dialOldC, "c-dial-old", @["c-extra", "c-units"])
    check opened(contractPackage([alphaNewE, dialNewE, unused])) == "invalid-package"
    let repeated: Entry = (dialOldC, "c-dial-old", @["c-units", "c-units"])
    check opened(contractPackage([alphaNewE, dialNewE, repeated])) == "invalid-package"
    # An entry whose document is a supporting schema.
    let supportingEntry: Entry = (unitsC, "c-units", newSeq[string]())
    check opened(contractPackage([supportingEntry], Opt.none(CborValue), @[], @[])) ==
      "invalid-package"

  test "[TXT-0458] [IMPL-DECISION G392] each document is Logos-defined or ordinary by its own contract name":
    let logosModule =
      "_module = \"logos_probe\"\n\nlogos_probe.ping_request = {}\n" &
      "logos_probe.ping_response = {}\n"
    let logosIface =
      "_interface = \"logos.probe\"\n\nlogos.probe.read_request = {}\n" &
      "logos.probe.read_response = {}\n"
    let usesLogos =
      "_module = \"probe_module\"\n" & implementing(rootOf(logosIface)) &
      "\nprobe.ping_request = {}\nprobe.ping_response = {}\n"
    # (`_module` is not committed, so its declarations differ from logosModule's.)
    let reservedInOrdinary =
      "_module = \"probe_module\"\n\nlogos_probe.poke_request = {}\n" &
      "logos_probe.poke_response = {}\n"
    let named = @[
      ("p-logos-iface", logosIface),
      ("p-logos-module", logosModule),
      ("p-reserved", reservedInOrdinary),
      ("p-uses-logos", usesLogos),
    ]
    let held: seq[Entry] = @[
      (schemaCommitment(rootOf(logosModule)), "p-logos-module", newSeq[string]()),
      (schemaCommitment(rootOf(logosIface)), "p-logos-iface", newSeq[string]()),
      (
        schemaCommitment(rootOf(usesLogos, [logosIface])),
        "p-uses-logos",
        @["p-logos-iface"],
      ),
    ]
    let none = Opt.none(CborValue)
    check opened(contractPackage(held, none, @[], @[], named)) == "ok"
    # An ordinary document that declares a reserved name, whatever its
    # commitment under the system options.
    let reserved: Entry = (
      schemaCommitment(rootOf(reservedInOrdinary, opts = AcceptOptions(system: true))),
      "p-reserved",
      newSeq[string](),
    )
    check opened(contractPackage(held & @[reserved], none, @[], @[], named)) ==
      "invalid-package"

  test "[PKG-0580] [PKG-0589] [IMPL-DECISION G392] an extends entry is extended by the declaring module's contracts":
    # Holds: the primary extends the earlier concrete contract, dial the earlier dial.
    check opened(contractPackage(everyEntry)) == "ok"
    # Every declared contract has an entry and none extends a changed declaration.
    let changedExtends = @[alphaChangedC, dialOldC]
    check opened(
      contractPackage(
        [alphaNewE, alphaChangedE, dialNewE, dialOldE], extends = changedExtends
      )
    ) == "invalid-package"
    # The declared contract of the namespace has an entry and does not extend it,
    # while another declared contract has none.
    check opened(
      contractPackage([alphaNewE, alphaChangedE, dialOldE], extends = changedExtends)
    ) == "invalid-package"
    # The same namespace with the other role.
    check opened(
      contractPackage(
        [alphaNewE, alphaIfaceE, dialOldE], extends = @[alphaIfaceC, dialOldC]
      )
    ) == "invalid-package"
    # Every declared contract has an entry and none shares the namespace.
    check opened(contractPackage([alphaNewE, dialNewE, gaugeE], extends = @[gaugeC])) ==
      "invalid-package"
    # The pair has no entry (dial's own contract), so the Package Manager cannot
    # decide and the Runtime validates.
    check opened(contractPackage([alphaNewE, dialOldE], extends = @[dialOldC])) == "ok"
    # Every declaration of the manifest counts, not only the selected variant's:
    # beta_module is in the linux variant only.
    let onBeta = contractPackage(
      [alphaNewE, alphaChangedE, dialNewE, dialOldE],
      extends = changedExtends,
      module = 1,
    )
    check opened(onBeta, darwinHost) == "invalid-package"

suite "pkg.lgx: the streaming reader agrees with the oracle on every archive built here (step 5-5-2b)":
  test "[IMPL-DECISION G446] [IMPL-DECISION G29] each archive this suite built or opened: the same result as the in-memory reader's, over bytes and over a file, and extracted to the same bytes":
    let scratch = getTempDir() / "lcn-test-lgx-" & $getCurrentProcessId()
    createDir(scratch)
    defer:
      removeDir(scratch)
    var seen = initHashSet[seq[byte]]()
    var kinds = initCountTable[Agreement]()
    for b in built:
      let key =
        @(blake3(b.archive)) &
        encodeCbor(
          cborArray(
            cbor(b.host.os),
            cbor(b.host.architecture),
            cbor(b.host.abi.get("")),
            cbor($b.limits),
            cbor($b.rules),
          )
        )
      if seen.containsOrIncl(key):
        continue
      let r = checkReaders(b.archive, trust, b.host, b.limits, b.rules, scratch)
      if r.isErr:
        checkpoint r.error
        fail()
      else:
        kinds.inc(r.get)
    checkpoint $seen.len & " archives: " & $kinds
    check seen.len > 100
