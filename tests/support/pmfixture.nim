## Fixtures for the Package Manager suites (Tier 5 step 5-3b): trust files,
## protected inputs and catalog entries.

import std/[algorithm, os, sequtils, times]
import results
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import ../../src/logos_core/crypto/slhdsa
import ../../src/logos_core/package/[lgx, manifest, records, signing, trust, trustdoc]
from ../../src/logos_core/package/resolver import
  MaxResolverLimits, names, depth, candidates, attempts
import ../../src/logos_core/pm/[input, catalog]

export
  results, cbor, blake3, slhdsa, lgx, manifest, records, signing, trust, trustdoc,
  input, catalog

proc bytesOf*(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

proc textOf*(b: openArray[byte]): string =
  for x in b:
    result.add(char(x))

proc treeOf*(dir: string): seq[string] =
  ## Every entry below `dir` with its kind, mode, size and modification time: what a
  ## start that changes nothing leaves as it was (G505's format refusal).
  for path in walkDirRec(
    dir, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}, relative = true
  ):
    let i = getFileInfo(dir / path, followSymlink = false)
    result.add(
      path & " " & $i.kind & " " & $i.permissions & " " & $i.size & " " &
        $i.lastWriteTime.toUnixFloat
    )
  result.sort()

proc testKey*(fill: byte): (SecretKey, PublicKey) =
  ## A fixed SLH-DSA-SHA2-192s key pair (FIPS 205 `slh_keygen_internal`).
  var a, b, c: Seed
  for i in 0 ..< N:
    a[i] = byte(i * 3) xor fill
    b[i] = byte(i * 5) xor fill
    c[i] = byte(i * 7) xor fill
  keyPairFromSeeds(a, b, c)

proc anchorOf*(kid: string, names: openArray[string], fill = 1'u8): LcnTrustAnchor =
  LcnTrustAnchor(
    kid: bytesOf(kid), public_key: newSeqWith(PublicKeyBytes, fill), packages: @names
  )

proc anchorOf*(kid: string, names: openArray[string], key: PublicKey): LcnTrustAnchor =
  LcnTrustAnchor(kid: bytesOf(kid), public_key: @key, packages: @names)

proc trustOf*(anchors: openArray[LcnTrustAnchor], revision = 2'u64): LcnPackageTrust =
  LcnPackageTrust(revision: revision, signing: LcnTrustSigning(anchors: @anchors))

proc trustBytes*(t: LcnPackageTrust): seq[byte] =
  t.encode.get

proc lgxSource*(storage, locator: string): PackageSource =
  PackageSource(kind: skLgx, storage: storage, objectLocator: bytesOf(locator))

proc entryOf*(name, version: string, storage = "main", locator = ""): CatalogEntry =
  CatalogEntry(
    identity: PackageIdentity(package: name, version: version),
    source: lgxSource(
      storage,
      if locator.len > 0:
        locator
      else:
        name & "@" & version,
    ),
  )

proc catalogBytes*(entries: openArray[CatalogEntry], sequence = 1'u64): seq[byte] =
  encodeCatalog(sequence, entries).get

proc pinOf*(
    document: openArray[byte], storage = "main", locator = "catalog"
): PmCatalogRef =
  PmCatalogRef(storage: storage, locator: bytesOf(locator), digest: blake3(document))

func limitsValue*(l: ResolverLimits): LcnPmResolverLimits =
  ## [G399] `l` as `lcn.pm_input`'s `resolver_limits`.
  LcnPmResolverLimits(
    partial_closure_names: uint64(l.names),
    dependency_depth: uint64(l.depth),
    candidates_per_name: uint64(l.candidates),
    assignment_attempts: uint64(l.attempts),
  )

proc pmValue*(
    trust: seq[byte],
    document: openArray[byte],
    bindings: openArray[(string, string)] = [("main", "storage_module")],
    catalogStorage = "main",
    limits = Opt.none(LcnPmLimits),
    resolverLimits = limitsValue(MaxResolverLimits),
    catalogLocator = "catalog",
): LcnPmInput =
  var storage: seq[LcnPmBinding]
  for (b, i) in bindings:
    storage.add(LcnPmBinding(binding: b, instance: i))
  LcnPmInput(
    trust: trust,
    storage: storage,
    catalog: LcnPmCatalogRef(
      storage: catalogStorage,
      `object`: bytesOf(catalogLocator),
      digest: @(blake3(document)),
    ),
    resolver_limits: resolverLimits,
    limits: limits,
  )

proc defaultTrust*(): seq[byte] =
  trustOf([anchorOf("org", ["logos.example", "logos.wallet"])]).trustBytes

# Signed LGX packages -----------------------------------------------------------------

let linuxHost* = Platform(os: "linux", architecture: "x86_64")
let darwinHost* = Platform(os: "darwin", architecture: "aarch64")

proc payloadOf*(name, version: string): seq[byte] =
  bytesOf("data of " & name & "@" & version)

proc variantValue(id, os, arch: string, hash: seq[byte]): CborValue =
  cborMap(
    (cbor("id"), cbor(id)),
    (
      cbor("platform"),
      cborMap((cbor("os"), cbor(os)), (cbor("architecture"), cbor(arch))),
    ),
    (
      cbor("artifacts"),
      cborArray(
        cborMap(
          (cbor("id"), cbor("data")),
          (cbor("kind"), cbor("data")),
          (cbor("path"), cbor("data/payload.bin")),
          (cbor("hash"), cbor(hash)),
        )
      ),
    ),
  )

proc dataManifest*(
    name, version: string,
    deps: openArray[(string, string)] = [],
    variants: openArray[(string, string, string)] =
      [("linux-x86_64", "linux", "x86_64")],
): CborValue =
  ## A package with no module, one data artifact per variant, and `deps` as
  ## `compatible` requirements.
  let hash = @(blake3(payloadOf(name, version)))
  var vs: seq[CborValue]
  for (id, os, arch) in variants:
    vs.add(variantValue(id, os, arch, hash))
  var ds: seq[CborValue]
  for (dep, at) in deps:
    ds.add(
      cborMap(
        (cbor("package"), cbor(dep)),
        (
          cbor("requirement"),
          cborMap((cbor("kind"), cbor("compatible")), (cbor("version"), cbor(at))),
        ),
      )
    )
  var entries = @[
    (cbor("package"), cbor(name)),
    (cbor("version"), cbor(version)),
    (cbor("modules"), cborArray()),
    (cbor("variants"), CborValue(kind: ckArray, items: vs)),
  ]
  if ds.len > 0:
    entries.add((cbor("dependencies"), CborValue(kind: ckArray, items: ds)))
  CborValue(kind: ckMap, entries: entries)

proc packed*(v: CborValue, kid: string, key: SecretKey): seq[byte] =
  ## The signed archive of manifest `v`, with every variant's payload. Signing
  ## takes about a second, so suites build their archives once.
  let m = decodeManifest(encodeCbor(v)).get
  let cose = signManifest(m, bytesOf(kid), key).get
  var dirs: seq[(string, seq[(string, seq[byte])])]
  for variant in m.variants:
    dirs.add((variant.id, @[("data/payload.bin", payloadOf(m.package, m.version))]))
  writeLgx(m.encoded, cose, dirs).get

proc trustInputOf*(anchors: openArray[(string, PublicKey, seq[string])]): TrustInput =
  for (kid, key, names) in anchors:
    doAssert result.addAnchor(bytesOf(kid), key, names).isOk
