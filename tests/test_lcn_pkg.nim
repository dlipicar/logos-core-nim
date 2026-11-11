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

proc str(data: openArray[byte]): string =
  result = newString(data.len)
  for i, x in data:
    result[i] = char(x)

proc put(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

proc keyOf(path: string): SecretKey =
  let raw = hex.fromHex(readFile(path).strip).get
  doAssert raw.len == SecretKeyBytes
  copyMem(addr result[0], unsafeAddr raw[0], SecretKeyBytes)

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
  keyPath = work / "dev.key"
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
  test "[PKG-0442] [IMPL-DECISION I41] keygen makes a fresh FIPS 205 key pair, readable only by its owner, and never overwrites one":
    let other = work / "other.key"
    check:
      keygen(keyPath) == 0
      keygen(other) == 0
      keyOf(keyPath) != keyOf(other)
    when defined(posix):
      check getFilePermissions(keyPath) == {fpUserRead, fpUserWrite}
    # The file is the FIPS 205 secret key SK.seed || SK.prf || PK.seed || PK.root:
    # its key pair signs and verifies.
    let k = keyOf(keyPath)
    let sig = sign(k, b("m")).get
    check verify(publicKey(k), b("m"), sig)
    let before = readFile(keyPath)
    check:
      keygen(keyPath) == 1
      readFile(keyPath) == before

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

  test "sign: a local key and an external signer (--emit-tbs, --attach-sig) differ only in the hedged signature":
    let tbs = work / "tbs.bin"
    let sig = work / "sig.hex"
    let external = work / "external.cose"
    check:
      signCmd(manifestPath, "dev-1", keyPath, "", "", cosePath) == 0
      signCmd(manifestPath, "dev-1", "", tbs, "", "") == 0
    # Signing is hedged, so the two objects differ only in their signatures.
    let externalSig = sign(keyOf(keyPath), b(readFile(tbs))).get
    put(sig, externalSig.toHex & "\n")
    check:
      signCmd(manifestPath, "dev-1", "", "", sig, external) == 0
      readFile(external).len == readFile(cosePath).len
      readFile(external)[0 ..< ^SignatureBytes] ==
        readFile(cosePath)[0 ..< ^SignatureBytes]
      readFile(external)[^SignatureBytes .. ^1] == str(externalSig)
      # A signature of the wrong length is refused.
    put(work / "short.sig", externalSig[0 ..< 64].toHex)
    check:
      signCmd(manifestPath, "dev-1", "", "", work / "short.sig", work / "short.cose") ==
        1
      # Exactly one of the three modes.
      signCmd(manifestPath, "dev-1", keyPath, tbs, "", "") == 1
      signCmd(manifestPath, "dev-1", "", "", "", "") == 1

  test "lgx pack, then verify against a trust file, per platform":
    let key = publicKey(keyOf(keyPath))
    trustFile(trustPath, key, @["logos.example"])
    check:
      lgxPack(manifestPath, cosePath, variants, packagePath) == 0
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
