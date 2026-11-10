## lcn-pkg, the package-producer tools (PM §4, §4.3, §7.1): each command as the
## CLI runs it, on files under build/scratch/test_lcn_pkg.

import std/[json, os, strutils]
import unittest2
import ../src/logos_core/base/hex
import ../src/logos_core/crypto/blake3
import ../src/logos_core/package/lgx
import ../src/lcn_pkg

const work = "build" / "scratch" / "test_lcn_pkg"

proc b(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

proc put(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

proc seedOf(path: string): Seed =
  let raw = hex.fromHex(readFile(path).strip).get
  var s: Seed
  for i in 0 ..< SeedLen:
    s[i] = raw[i]
  s

proc trustFile(path: string, key: PublicKey, packages: seq[string]) =
  put(
    path,
    $ %*{"anchors": [{"kid": "dev-1", "public_key": key.toHex, "packages": packages}]},
  )

# The artifacts' hashes are left empty: `manifest build` fills them in.
const source = """
{
  "package": "logos.example",
  "version": "0.1.0",
  "modules": [{"module": "alpha_module", "artifact": "alpha"}],
  "variants": [
    {"id": "linux-x86_64", "platform": {"os": "linux", "architecture": "x86_64", "abi": "gnu"},
     "artifacts": [{"id": "alpha", "kind": "module-binary", "path": "lib/libalpha.so", "hash": h''}]},
    {"id": "darwin-aarch64", "platform": {"os": "darwin", "architecture": "aarch64"},
     "artifacts": [{"id": "alpha", "kind": "module-binary", "path": "lib/libalpha.dylib", "hash": h''}]},
  ],
}
"""

let
  seedPath = work / "dev.seed"
  edn = work / "manifest.edn"
  variants = work / "variants"
  manifestPath = work / "manifest.cbor"
  cosePath = work / "manifest.cose"
  packagePath = work / "example.lgx"
  trustPath = work / "trust.json"

removeDir(work)
put(edn, source)
put(variants / "linux-x86_64" / "lib" / "libalpha.so", "ALPHA for linux")
put(variants / "darwin-aarch64" / "lib" / "libalpha.dylib", "ALPHA for darwin")

suite "pkg.cli: lcn-pkg producer commands":
  test "[PKG-0108] keygen draws a fresh seed, readable only by its owner, and never overwrites one":
    let other = work / "other.seed"
    check:
      keygen(seedPath) == 0
      keygen(other) == 0
      seedOf(seedPath) != seedOf(other)
    when defined(posix):
      check getFilePermissions(seedPath) == {fpUserRead, fpUserWrite}
    let before = readFile(seedPath)
    check:
      keygen(seedPath) == 1
      readFile(seedPath) == before

  test "[PKG-0020] manifest build generates the manifest from a source and the variant files":
    check manifestBuild(edn, variants, manifestPath) == 0
    let m = decodeManifest(b(readFile(manifestPath))).get
    check:
      m.package == "logos.example"
      m.variants.len == 2
    for v in m.variants:
      for a in v.artifacts:
        check a.hash == blake3(b(readFile(variants / v.id / a.path)))
    # A missing variant file and a path outside the variant are refused.
    let missing = work / "missing.edn"
    put(missing, source.replace("libalpha.so", "libgone.so"))
    let escaping = work / "escaping.edn"
    put(escaping, source.replace("lib/libalpha.so", "../libalpha.so"))
    check:
      manifestBuild(missing, variants, work / "missing.cbor") == 1
      manifestBuild(escaping, variants, work / "escaping.cbor") == 1
      not fileExists(work / "missing.cbor")

  test "sign: a local key and an external signer (--emit-tbs, --attach-sig) give the same object":
    let tbs = work / "tbs.bin"
    let sig = work / "sig.hex"
    let external = work / "external.cose"
    check:
      signCmd(manifestPath, "dev-1", seedPath, "", "", cosePath) == 0
      signCmd(manifestPath, "dev-1", "", tbs, "", "") == 0
    put(sig, keyFromSeed(seedOf(seedPath)).sign(b(readFile(tbs))).toHex & "\n")
    check:
      signCmd(manifestPath, "dev-1", "", "", sig, external) == 0
      readFile(external) == readFile(cosePath)
      # Exactly one of the three modes.
      signCmd(manifestPath, "dev-1", seedPath, tbs, "", "") == 1
      signCmd(manifestPath, "dev-1", "", "", "", "") == 1

  test "lgx pack, then verify against a trust file, per platform":
    let key = keyFromSeed(seedOf(seedPath)).publicKey
    trustFile(trustPath, key, @["logos.example"])
    check:
      lgxPack(manifestPath, cosePath, variants, "", packagePath) == 0
      verifyCmd(packagePath, trustPath, "linux/x86_64/gnu") == 0
      verifyCmd(packagePath, trustPath, "darwin/aarch64") == 0
      verifyCmd(packagePath, trustPath, "windows/x86_64") == 1
    var trust: TrustInput
    check trust.addAnchor(b("dev-1"), @key, @["logos.example"]).isOk
    let pkg = openLgx(
      b(readFile(packagePath)),
      trust,
      Platform(os: "linux", architecture: "x86_64", abi: Opt.some("gnu")),
    )
    check:
      pkg.isOk
      pkg.get.variant.id == "linux-x86_64"
    # A signer not authorized for this exact name.
    let narrow = work / "narrow.json"
    trustFile(narrow, key, @["logos.example2"])
    var narrowTrust: TrustInput
    check:
      verifyCmd(packagePath, narrow, "linux/x86_64/gnu") == 1
      narrowTrust.addAnchor(b("dev-1"), @key, @["logos.example2"]).isOk
      openLgx(
        b(readFile(packagePath)),
        narrowTrust,
        Platform(os: "linux", architecture: "x86_64", abi: Opt.some("gnu")),
      ).error.code == pecSignature
