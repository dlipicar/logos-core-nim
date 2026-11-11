## lcn-pkg: package-producer and checking tools for the PM §3/§4 manifest, the
## §4.3 COSE_Sign1 SLH-DSA-SHA2-192s profile and §7.1 LGX archives. A subset for
## now: no fetch, catalog, install or Nix profile.
##
## [IMPL] File formats that are tool conventions, not spec formats:
## - a manifest source is CBOR diagnostic notation (RFC 8949 §8); `manifest
##   build` fills each artifact `hash` from the variant directories and puts the
##   canonical arrays in order (variants keep theirs);
## - a key file holds the 96-byte FIPS 205 secret key `SK.seed || SK.prf ||
##   PK.seed || PK.root` as 192 hex digits, readable only by its owner (PM §4.3
##   leaves private-key storage to the producer);
## - a trust file is JSON: {"anchors": [{"kid": "<text>" | "kid_hex": "<hex>",
##   "public_key": "<hex>", "packages": ["<exact name>", ...]}]}.

import std/[algorithm, json, os, parseopt, strutils]
import results
import ./logos_core/base/hex
import ./logos_core/cbor
import ./logos_core/crypto/blake3
import ./logos_core/package/lgx

const usage = """
Usage:
  lcn-pkg keygen --out:KEY
  lcn-pkg manifest build SOURCE.edn --variants:DIR [--out:manifest.cbor]
  lcn-pkg sign MANIFEST.cbor --kid:KID --key:KEY [--out:manifest.cose]
  lcn-pkg sign MANIFEST.cbor --kid:KID --emit-tbs:FILE
  lcn-pkg sign MANIFEST.cbor --kid:KID --attach-sig:FILE [--out:manifest.cose]
  lcn-pkg lgx pack --manifest:manifest.cbor --cose:manifest.cose --variants:DIR
                   --out:PACKAGE.lgx
  lcn-pkg verify PACKAGE.lgx --trust:TRUST.json [--platform:OS/ARCH[/ABI]]

keygen         writes a fresh SLH-DSA-SHA2-192s secret key (FIPS 205 key
               generation from the operating-system CSPRNG, PM §4.3) readable
               only by its owner, and prints the 48-byte public key
manifest build fills artifact hashes from DIR/<variant id>/<path>, orders the
               canonical arrays, validates (PM §4, §5, §8) and writes the manifest
sign           signs the manifest's commitment claim (PM §4.3, hedged); --emit-tbs
               writes the Sig_structure bytes for an external signer (pure
               SLH-DSA-SHA2-192s, empty context) and --attach-sig takes its
               16224-byte signature (raw or hex)
lgx pack       writes an LGX archive (PM §7.1) from DIR/<variant id>/...
verify         opens a package: archive rules, signature against the trust
               file, variant selection (default: this host), artifact hashes

KID is text, or hex:<digits> for raw bytes.
"""

proc fail(msg: string): int =
  try:
    stderr.writeLine("lcn-pkg: " & msg)
  except IOError:
    discard
  1

proc bytesOf(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

proc readBytes(path: string): Result[seq[byte], string] =
  try:
    ok(bytesOf(readFile(path)))
  except CatchableError as e:
    err("cannot read " & path & ": " & e.msg)

proc writeBytes(path: string, data: openArray[byte]): Result[void, string] =
  try:
    let dir = path.parentDir
    if dir.len > 0:
      createDir(dir)
    var s = newString(data.len)
    for i, b in data:
      s[i] = char(b)
    writeFile(path, s)
    ok()
  except CatchableError as e:
    err("cannot write " & path & ": " & e.msg)

proc parseKid(s: string): Result[seq[byte], string] =
  if s.len == 0:
    return err("--kid is required")
  if s.startsWith("hex:"):
    return hex.fromHex(s[4 .. ^1])
  ok(bytesOf(s))

proc hexOrRaw(data: seq[byte], n: int): Result[seq[byte], string] =
  ## `n` raw bytes, or 2n hex digits with surrounding whitespace.
  if data.len == n:
    return ok(data)
  var s = ""
  for b in data:
    s.add(char(b))
  let h = hex.fromHex(s.strip)
  if h.isOk and h.get.len == n:
    return h
  err("expected " & $n & " raw bytes or " & $(2 * n) & " hex digits")

proc loadKey(path: string): Result[SecretKey, string] =
  ## The key file's secret key; the copies this code makes are cleared
  ## (best effort: the runtime may have moved others).
  var raw = ?readBytes(path)
  let parsed = hexOrRaw(raw, SecretKeyBytes)
  if raw.len > 0:
    zeroMem(addr raw[0], raw.len)
  var bytes = parsed.valueOr:
    return err(path & ": " & error)
  var k: SecretKey
  copyMem(addr k[0], addr bytes[0], SecretKeyBytes)
  zeroMem(addr bytes[0], bytes.len)
  ok(k)

proc loadTrust(path: string): Result[TrustInput, string] =
  var t: TrustInput
  try:
    let doc = parseJson(readFile(path))
    for a in doc["anchors"]:
      let kid =
        if a.hasKey("kid_hex"):
          ?hex.fromHex(a["kid_hex"].getStr)
        else:
          bytesOf(a["kid"].getStr)
      let key = ?hex.fromHex(a["public_key"].getStr)
      var names: seq[string]
      for p in a["packages"]:
        names.add(p.getStr)
      ?t.addAnchor(kid, key, names)
  except CatchableError as e:
    return err("cannot read trust file " & path & ": " & e.msg)
  ok(t)

proc parsePlatform(s: string): Result[Platform, string] =
  let parts = s.split('/')
  if parts.len notin 2 .. 3:
    return err("a platform is OS/ARCH or OS/ARCH/ABI")
  var p = Platform(os: parts[0], architecture: parts[1])
  if parts.len == 3:
    p.abi = Opt.some(parts[2])
  ok(p)

# Commands --------------------------------------------------------------------------

proc keygen*(output: string): int =
  if output.len == 0:
    return fail("--out is required")
  if fileExists(output):
    return fail(output & " exists; refusing to overwrite a key")
  var (sk, pk) = generateKeyPair().valueOr:
    return fail(error)
  # Created empty and restricted before the key is written.
  writeBytes(output, newSeq[byte]()).isOkOr:
    return fail(error)
  try:
    setFilePermissions(output, {fpUserRead, fpUserWrite})
  except CatchableError as e:
    return fail("cannot restrict " & output & ": " & e.msg)
  var text = sk.toHex & "\n"
  sk.clear()
  let written = writeBytes(output, bytesOf(text))
  zeroMem(addr text[0], text.len)
  written.isOkOr:
    return fail(error)
  echo "public key: ", pk.toHex
  0

proc text(v: CborValue, key: string): string =
  v.lookup(key).get(cbor("")).getText.get("")

proc sortItems(v: CborValue, key: string, by: proc(x: CborValue): seq[byte]) =
  let a = v.lookup(key)
  if a.isSome and a.get.kind == ckArray:
    a.get.items.sort(
      proc(x, y: CborValue): int =
        cmpBytes(by(x), by(y))
    )

proc canonicalize(m: CborValue) =
  ## [SPEC PM §4] The canonical array orders; `variants` keeps its order.
  let byText = proc(field: string): proc(x: CborValue): seq[byte] =
    proc(x: CborValue): seq[byte] =
      bytesOf(x.text(field))
  m.sortItems("modules", byText("module"))
  m.sortItems("dependencies", byText("package"))
  for d in m.lookup("modules").get(cborArray()).items:
    d.sortItems(
      "implements",
      proc(x: CborValue): seq[byte] =
        encodeCbor(x),
    )
    d.sortItems(
      "requires",
      proc(x: CborValue): seq[byte] =
        encodeCbor(x.lookup("contract").get(cborNull())),
    )
    d.sortItems("requested_permissions", byText("permission"))
  for v in m.lookup("variants").get(cborArray()).items:
    v.sortItems("artifacts", byText("id"))

proc fillHashes(m: CborValue, root: string): Result[void, string] =
  ## Each artifact's `hash`: the hash suite over DIR/<variant id>/<path> (§10).
  for v in m.lookup("variants").get(cborArray()).items:
    let id = v.text("id")
    for a in v.lookup("artifacts").get(cborArray()).items:
      let path = a.text("path")
      ?checkArtifactPath(path)
      let data = ?readBytes(root / id / path)
      var replaced = false
      for e in a.entries.mitems:
        if e.key.getText == Opt.some("hash"):
          e.value = cbor(blake3(data))
          replaced = true
      if not replaced:
        a.entries.add((cbor("hash"), cbor(blake3(data))))
  ok()

proc manifestBuild*(source, variants, output: string): int =
  if source.len == 0 or variants.len == 0:
    return fail("manifest build needs SOURCE.edn and --variants\n" & usage)
  let src =
    try:
      readFile(source)
    except CatchableError as e:
      return fail("cannot read " & source & ": " & e.msg)
  let v = parseDiag(src).valueOr:
    return fail(source & ": " & error)
  if v.kind != ckMap:
    return fail(source & " is not a map")
  canonicalize(v)
  fillHashes(v, variants).isOkOr:
    return fail(error)
  let m = decodeManifest(encodeCbor(v)).valueOr:
    return fail($error)
  let c = m.commitment.valueOr:
    return fail($error)
  writeBytes(output, m.encoded).isOkOr:
    return fail(error)
  echo output
  echo "value root: ", c.valueRoot.toHex
  0

proc signCmd*(manifest, kidText, keyPath, emitTbs, attachSig, output: string): int =
  if manifest.len == 0:
    return fail("sign needs MANIFEST.cbor\n" & usage)
  let kid = parseKid(kidText).valueOr:
    return fail(error)
  let raw = readBytes(manifest).valueOr:
    return fail(error)
  let m = decodeManifest(raw).valueOr:
    return fail($error)
  var modes = 0
  for given in [keyPath, emitTbs, attachSig]:
    if given.len > 0:
      inc modes
  if modes != 1:
    return fail("give exactly one of --key, --emit-tbs and --attach-sig")
  let target =
    if output.len > 0:
      output
    else:
      manifest.parentDir / ManifestCosePath
  if emitTbs.len > 0:
    let (_, tbs) = toBeSigned(m, kid).valueOr:
      return fail($error)
    writeBytes(emitTbs, tbs).isOkOr:
      return fail(error)
    echo emitTbs
    return 0
  let cose =
    if keyPath.len > 0:
      var key = loadKey(keyPath).valueOr:
        return fail(error)
      let r = signManifest(m, kid, key)
      key.clear()
      r
    else:
      let raw = readBytes(attachSig).valueOr:
        return fail(error)
      let sig = hexOrRaw(raw, SignatureBytes).valueOr:
        return fail(attachSig & ": " & error)
      attachSignature(m, kid, sig)
  let bytes = cose.valueOr:
    return fail($error)
  writeBytes(target, bytes).isOkOr:
    return fail(error)
  echo target
  0

proc variantFiles(dir: string): Result[seq[(string, seq[byte])], string] =
  ## Regular files under `dir`, by path relative to it; links and special
  ## files are refused (PM §7.1).
  var files: seq[(string, seq[byte])]
  if not dirExists(dir):
    return err("no variant directory " & dir)
  try:
    for path in walkDirRec(
      dir,
      yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
      followFilter = {pcDir},
      relative = true,
    ):
      let full = dir / path
      if symlinkExists(full):
        return err("a symbolic link: " & full)
      let info = getFileInfo(full, followSymlink = false)
      if info.kind != pcFile:
        return err("not a regular file: " & full)
      let data = ?readBytes(full)
      files.add((path.replace(DirSep, '/'), data))
  except CatchableError as e:
    return err("cannot list " & dir & ": " & e.msg)
  files.sort(
    proc(a, b: (string, seq[byte])): int =
      cmp(a[0], b[0])
  )
  ok(files)

proc lgxPack*(manifest, cose, variants, output: string): int =
  if manifest.len == 0 or cose.len == 0 or variants.len == 0 or output.len == 0:
    return fail("lgx pack needs --manifest, --cose, --variants and --out\n" & usage)
  let cbor = readBytes(manifest).valueOr:
    return fail(error)
  let signature = readBytes(cose).valueOr:
    return fail(error)
  let m = decodeManifest(cbor).valueOr:
    return fail($error)
  var content: seq[(string, seq[(string, seq[byte])])]
  for v in m.variants:
    let files = variantFiles(variants / v.id).valueOr:
      return fail(error)
    content.add((v.id, files))
  let archive = writeLgx(cbor, signature, content).valueOr:
    return fail(error)
  readLgx(archive).isOkOr:
    return fail("the written archive does not read back: " & $error)
  writeBytes(output, archive).isOkOr:
    return fail(error)
  echo output
  0

proc verifyCmd*(package, trustPath, platform: string): int =
  if package.len == 0 or trustPath.len == 0:
    return fail("verify needs PACKAGE.lgx and --trust\n" & usage)
  let data = readBytes(package).valueOr:
    return fail(error)
  let trust = loadTrust(trustPath).valueOr:
    return fail(error)
  let p =
    if platform.len > 0:
      parsePlatform(platform).valueOr:
        return fail(error)
    else:
      hostPlatform()
  let pkg = openLgx(data, trust, p).valueOr:
    return fail($error)
  let m = pkg.verified.manifest
  echo "package: ", m.package, " ", m.version
  echo "signer: ", pkg.verified.signer.kid.toHex
  echo "value root: ", pkg.verified.commitment.valueRoot.toHex
  echo "variant: ", pkg.variant.id
  for d in pkg.modules:
    echo "module: ", d.module, " (", d.artifact, ")"
  0

proc main(): int =
  var
    args: seq[string]
    opts: seq[(string, string)]
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      args.add(key)
    of cmdLongOption, cmdShortOption:
      if key in ["help", "h"]:
        echo usage
        return 0
      opts.add((key, val))
    of cmdEnd:
      discard
  proc opt(name: string): string =
    for (k, v) in opts:
      if k == name:
        return v
    ""

  const known = [
    "out", "variants", "kid", "key", "emit-tbs", "attach-sig", "manifest", "cose",
    "trust", "platform",
  ]
  for (k, _) in opts:
    if k notin known:
      return fail("unknown option --" & k & "\n" & usage)
  if args.len == 0:
    return fail(usage.strip)
  case args[0]
  of "keygen":
    keygen(opt("out"))
  of "manifest":
    if args.len < 2 or args[1] != "build":
      return fail(usage.strip)
    let output =
      if opt("out").len > 0:
        opt("out")
      else:
        ManifestCborPath
    manifestBuild(
      if args.len > 2:
        args[2]
      else:
        "",
      opt("variants"),
      output,
    )
  of "sign":
    signCmd(
      if args.len > 1:
        args[1]
      else:
        "",
      opt("kid"),
      opt("key"),
      opt("emit-tbs"),
      opt("attach-sig"),
      opt("out"),
    )
  of "lgx":
    if args.len < 2 or args[1] != "pack":
      return fail(usage.strip)
    lgxPack(opt("manifest"), opt("cose"), opt("variants"), opt("out"))
  of "verify":
    verifyCmd(
      if args.len > 1:
        args[1]
      else:
        "",
      opt("trust"),
      opt("platform"),
    )
  else:
    fail(usage.strip)

when isMainModule:
  quit(main())
