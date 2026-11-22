## PM §5, §6, §11: catalog entries, source and inspection records, and
## dependency resolution. The resolver tests use a synthetic catalog whose
## inspector answers from a table (commitments are opaque to resolution) and
## logs every source it is asked about; one test resolves real signed LGX
## packages through `lgxInspector`.

import std/[algorithm, random, sequtils, sets, strutils, tables]
import unittest2
import logos_sdk/[cbor, pins]
import logos_sdk/base/hex
import logos_sdk/testing/specdata
import logos_sdk/crypto/blake3, ../src/logos_core/crypto/slhdsa
import ../src/logos_core/pins as core_pins
import ../src/logos_core/package/[lgx, resolver, signing, trust]
import ../src/logos_core/daemon/config
import ./support/[oracle_resolver, pmshapes]

proc b(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

proc str(s: seq[byte]): string =
  for c in s:
    result.add(char(c))

proc digestOf(h: string): typeof(ManifestCommitment().schemaRoot) =
  let bytes = hex.fromHex(h).get
  for i in 0 ..< result.len:
    result[i] = bytes[i]

proc commitOf(seed: string, supported = true): ManifestCommitment =
  ## A commitment under the pinned manifest schema, or, when not `supported`,
  ## under another schema root.
  ManifestCommitment(
    commitmentModel: CommitmentModelId,
    schemaRoot:
      if supported:
        digestOf(core_pins.PackageManifestSchemaRoot)
      else:
        blake3(b("another schema")),
    schemaSubtreeRoot: digestOf(core_pins.PackageManifestSubtreeRoot),
    valueRoot: blake3(b(seed)),
    hashProfile: HashProfileId,
    hashSuite: HashSuiteId,
  )

proc ident(s: string): PackageIdentity =
  let at = s.find('@')
  PackageIdentity(package: s[0 ..< at], version: s[at + 1 .. ^1])

proc contract(name: string): CborValue =
  ## A stand-in for a schema commitment: resolution compares contracts by
  ## their encoding only.
  cbor("contract " & name)

proc dep(s: string): PackageDependency =
  ## "name ^min" (compatible) or "name =version" (exact), then "+K" for each
  ## contract it lists.
  let parts = s.split(' ')
  PackageDependency(
    package: parts[0],
    kind: if parts[1][0] == '=': rkExact else: rkCompatible,
    version: parts[1][1 .. ^1],
    contracts: parts[2 .. ^1].mapIt(contract(it[1 .. ^1])),
  )

proc edge(s: string): ResolvedDependency =
  ## "name@version", or "name@version/seed" for another commitment.
  let at = s.find('/')
  if at < 0:
    ResolvedDependency(identity: ident(s), commitment: commitOf(s))
  else:
    ResolvedDependency(
      identity: ident(s[0 ..< at]), commitment: commitOf(s[0 ..< at] & s[at + 1 .. ^1])
    )

proc providing(contracts: openArray[string]): seq[ModuleDeclaration] =
  ## One module declaration whose `implements` lists the contracts.
  if contracts.len > 0:
    result.add(
      ModuleDeclaration(module: "m", implements: contracts.mapIt(contract(it)))
    )

proc source(name, version: string, n = 0): PackageSource =
  PackageSource(
    kind: skLgx, storage: "test", objectLocator: b(name & "@" & version & "#" & $n)
  )

# A synthetic catalog ------------------------------------------------------------------

type
  Universe = ref object
    catalog: seq[CatalogEntry]
    outcomes: Table[seq[byte], Inspection]
    installed: seq[InstalledPackage]
    log: seq[string] ## the sources inspected, in order
    altered: HashSet[string] ## installed identities whose retained bytes are altered
    checked: seq[string] ## the installed records whose retained bytes were checked

  Outcome = object
    res: Result[Resolution, PackageError]
    counters: ResolverCounters

proc add(
    u: Universe,
    name, version: string,
    deps: openArray[string] = [],
    seed = "",
    n = 0,
    outcome = ikEligible,
    claims = "",
    provides: openArray[string] = [],
    code = pecSignature,
) =
  ## A catalog entry for name@version and what inspecting its source yields:
  ## eligible, or ineligible with `code`.
  let s = source(name, version, n)
  u.catalog.add(
    CatalogEntry(identity: PackageIdentity(package: name, version: version), source: s)
  )
  u.outcomes[s.encoded] =
    case outcome
    of ikEligible:
      Inspection(
        kind: ikEligible,
        identity:
          if claims.len > 0:
            ident(claims)
          else:
            ident(name & "@" & version),
        commitment: commitOf(name & "@" & version & seed),
        dependencies: deps.mapIt(dep(it)),
        provides: provided(providing(provides)),
      )
    of ikIneligible:
      Inspection(kind: ikIneligible, error: packageError(code, "test: " & $code))
    of ikUnavailable:
      Inspection(kind: ikUnavailable, reason: "test: the source is unreachable")

proc publicKey(fill: byte): PublicKey =
  for i in 0 ..< PublicKeyBytes:
    result[i] = fill

let
  acceptedKey = publicKey(0x11) ## the universe's trust input accepts it for every name
  withdrawnKey = publicKey(0x22) ## no anchor holds it

proc install(
    u: Universe,
    name, version: string,
    deps: openArray[string] = [],
    edges: openArray[string] = [],
    seed = "",
    provides: openArray[string] = [],
    withdrawn = false,
    supported = true,
    n = 0,
) =
  ## An installed record; its recorded edges name installed identities. Its
  ## retained signer is accepted unless `withdrawn`, and its retained source
  ## is `source(name, version, n)`.
  u.installed.add(
    InstalledPackage(
      identity: PackageIdentity(package: name, version: version),
      commitment: commitOf(name & "@" & version & seed, supported),
      signer: PackageSigner(
        profile: signingProfile(), key: if withdrawn: withdrawnKey else: acceptedKey
      ),
      source: source(name, version, n),
      modules: providing(provides),
      dependencies: deps.mapIt(dep(it)),
      resolvedDependencies: edges.mapIt(edge(it)),
    )
  )

proc trust(u: Universe): TrustInput =
  ## One anchor holding `acceptedKey` for every installed name.
  var names = @["none"]
  for p in u.installed:
    names.add(p.identity.package)
  doAssert result.addAnchor(b("universe"), acceptedKey, names).isOk

proc inspector(u: Universe): Inspector =
  let outcomes = u.outcomes
  result = proc(
      s: PackageSource, trust: TrustInput
  ): Inspection {.gcsafe, raises: [].} =
    u.log.add(str(s.objectLocator))
    outcomes.getOrDefault(
      s.encoded, Inspection(kind: ikUnavailable, reason: "test: no such source")
    )

proc retained(u: Universe): RetainedCheck =
  result = proc(p: InstalledPackage): Result[void, string] {.gcsafe, raises: [].} =
    u.checked.add($p.identity)
    if $p.identity in u.altered:
      err("test: a retained artifact is altered")
    else:
      ok()

let intact: RetainedCheck = proc(
    p: InstalledPackage
): Result[void, string] {.gcsafe, raises: [].} =
  ok()

proc limits(
    names = 100, depth = 100, candidates = 100, attempts = 10_000
): ResolverLimits =
  resolverLimits(names, depth, candidates, attempts).get

proc resolveRoot(u: Universe, root: RootReference, lim = limits()): Outcome =
  u.log.setLen(0)
  u.checked.setLen(0)
  var c: ResolverCounters
  let input = ResolverInput(
    installed: u.installed,
    catalog: u.catalog,
    limits: lim,
    trust: u.trust,
    inspect: u.inspector,
    retained: u.retained,
  )
  let r = resolve(input, root, c)
  Outcome(res: r, counters: c)

proc resolveName(u: Universe, name: string, version = "", lim = limits()): Outcome =
  u.resolveRoot(
    RootReference(
      package: Opt.some(name),
      version:
        if version.len > 0:
          Opt.some(version)
        else:
          Opt.none(string),
    ),
    lim,
  )

proc update(u: Universe, current: string, target = "", via = ""): Outcome =
  ## `update_package`'s root: `current`, an optional target version and an
  ## optional source ("name@version#n").
  var root = RootReference(newerThan: Opt.some(ident(current)))
  if target.len > 0:
    root.version = Opt.some(target)
  if via.len > 0:
    let at = via.find('#')
    let id = ident(via[0 ..< at])
    root.source = Opt.some(source(id.package, id.version, parseInt(via[at + 1 .. ^1])))
  u.resolveRoot(root)

proc code(o: Outcome): string =
  if o.res.isOk:
    "ok"
  else:
    checkpoint o.res.error.msg
    $o.res.error.code

proc picked(o: Outcome): seq[string] =
  if o.res.isErr:
    checkpoint o.res.error.msg
    return @[$o.res.error.code]
  o.res.get.packages.mapIt($it.identity)

proc chosen(o: Outcome, name: string): SelectedPackage =
  for p in o.res.get.packages:
    if p.identity.package == name:
      return p

proc considered(o: Outcome, name: string): int =
  for (n, c) in o.counters.considered:
    if n == name:
      return c

# Records ------------------------------------------------------------------------------

proc identityValue(package, version: string): CborValue =
  cborMap((cbor("package"), cbor(package)), (cbor("version"), cbor(version)))

proc lgxSource(obj: seq[byte], extra: varargs[CborEntry]): CborValue =
  result = cborMap(
    (cbor("kind"), cbor("lgx")),
    (cbor("storage"), cbor("main")),
    (cbor("object"), cbor(obj)),
  )
  for e in extra:
    result.entries.add(e)

proc entryValue(identity, source: CborValue): CborValue =
  cborMap((cbor("identity"), identity), (cbor("source"), source))

suite "pkg.catalog: catalog entries, source and inspection records (PM §5, §6)":
  test "[PKG-0184] [PKG-0295] catalog entries, sources and resolved edges are the mirrored records":
    let lgxEntry = CatalogEntry(
      identity: ident("logos.example@1.2.0-rc.1"),
      source: PackageSource(
        kind: skLgx,
        storage: "main",
        objectLocator: b("archive"),
        provenanceLocator: Opt.some(b("provenance")),
      ),
    )
    let nixEntry = CatalogEntry(
      identity: ident("logos.example@1.2.0"),
      source: PackageSource(
        kind: skNix,
        flakeRef: "github:logos-co/example",
        attr: Opt.some("packages.x86_64-linux.default"),
        lockedRef: Opt.some("github:logos-co/example/0123abc"),
      ),
    )
    for e in [lgxEntry, nixEntry]:
      let back = decodeCatalogEntry(decodeCbor(encodeCbor(e.toCbor)).get)
      check back.isOk
      check back.get.identity == e.identity
      check back.get.source == e.source
    let edge =
      ResolvedDependency(identity: ident("dep@0.3.1"), commitment: commitOf("x"))
    let edgeBack = decodeResolvedDependency(edge.toCbor)
    check edgeBack.isOk
    check edgeBack.get == edge

    let id = identityValue("p", "1.0.0")
    check decodeCatalogEntry(entryValue(id, lgxSource(b("o")))).isOk
    # The CDDL: closed maps, the source arms, sizes.
    check decodeCatalogEntry(entryValue(id, lgxSource(@[]))).isErr
    check decodeCatalogEntry(entryValue(id, lgxSource(newSeq[byte](4097)))).isErr
    check decodeCatalogEntry(entryValue(id, lgxSource(b("o"), (cbor("x"), cbor(1))))).isErr
    check decodeCatalogEntry(
      entryValue(id, lgxSource(b("o"), (cbor("flake_ref"), cbor("f"))))
    ).isErr
    check decodeCatalogEntry(
      entryValue(
        id, cborMap((cbor("kind"), cbor("tar")), (cbor("object"), cbor(b("o"))))
      )
    ).isErr
    check decodeCatalogEntry(cborMap((cbor("identity"), id))).isErr
    # [SPEC PM §5] The version is SemVer text, complete in the identity.
    for bad in ["v1.0.0", "1.0.0+build", "1.0", "01.0.0", "1.0.0-"]:
      check decodeCatalogEntry(entryValue(identityValue("p", bad), lgxSource(b("o")))).isErr
    check decodeIdentity(identityValue("", "1.0.0")).isErr

  test "[PKG-0186] a provenance locator differs from the archive locator":
    let id = identityValue("p", "1.0.0")
    check decodeCatalogEntry(
      entryValue(id, lgxSource(b("o"), (cbor("provenance_object"), cbor(b("p")))))
    ).isOk
    check decodeCatalogEntry(
      entryValue(id, lgxSource(b("o"), (cbor("provenance_object"), cbor(b("o")))))
    ).isErr

# Real packages --------------------------------------------------------------------------

proc testKey(fill: byte): (SecretKey, PublicKey) =
  var a, b, c: Seed
  for i in 0 ..< N:
    a[i] = byte(i * 3) xor fill
    b[i] = byte(i * 5) xor fill
    c[i] = byte(i * 7) xor fill
  keyPairFromSeeds(a, b, c)

let (goodKey, goodPub) = testKey(1)
let (rogueKey, roguePub) = testKey(2)
var anchors: TrustInput
doAssert anchors.addAnchor(b("good"), goodPub, ["app", "lib"]).isOk
doAssert anchors.addAnchor(b("rogue"), roguePub, ["app"]).isOk
let linuxHost = Platform(os: "linux", architecture: "x86_64")

proc schemaCommitment(): CborValue =
  cborMap(
    (cbor("commitment_model"), cbor(CommitmentModelId)),
    (cbor("schema_root"), cbor(newSeq[byte](32))),
    (cbor("hash_profile"), cbor(HashProfileId)),
    (cbor("hash_suite"), cbor(HashSuiteId)),
  )

let binary = b("module binary")

proc variant(id, os, arch: string, artifact: CborValue): CborValue =
  cborMap(
    (cbor("id"), cbor(id)),
    (
      cbor("platform"),
      cborMap((cbor("os"), cbor(os)), (cbor("architecture"), cbor(arch))),
    ),
    (cbor("artifacts"), cborArray(artifact)),
  )

proc appManifest(): CborValue =
  ## A module that requires a provider and requests a permission, in two
  ## variants, with one package dependency.
  let art = cborMap(
    (cbor("id"), cbor("bin")),
    (cbor("kind"), cbor("module-binary")),
    (cbor("path"), cbor("lib/app.so")),
    (cbor("hash"), cbor(blake3(binary))),
  )
  cborMap(
    (cbor("package"), cbor("app")),
    (cbor("version"), cbor("1.0.0")),
    (
      cbor("modules"),
      cborArray(
        cborMap(
          (cbor("module"), cbor("app_module")),
          (cbor("artifact"), cbor("bin")),
          (
            cbor("requires"),
            cborArray(
              cborMap(
                (cbor("contract"), schemaCommitment()),
                (cbor("cardinality"), cbor("single")),
              )
            ),
          ),
          (
            cbor("requested_permissions"),
            cborArray(
              cborMap(
                (cbor("permission"), cbor("logos.example.permission")),
                (cbor("constraints"), cbor(encodeCbor(cborMap()))),
                (cbor("reason"), cbor("an example")),
              )
            ),
          ),
        )
      ),
    ),
    (
      cbor("variants"),
      cborArray(
        variant("linux-x86_64", "linux", "x86_64", art),
        variant("darwin-aarch64", "darwin", "aarch64", art),
      ),
    ),
    (
      cbor("dependencies"),
      cborArray(
        cborMap(
          (cbor("package"), cbor("lib")),
          (
            cbor("requirement"),
            cborMap(
              (cbor("kind"), cbor("compatible")), (cbor("version"), cbor("1.0.0"))
            ),
          ),
        )
      ),
    ),
  )

proc libManifest(
    version: string, id = "linux-x86_64", os = "linux", arch = "x86_64"
): CborValue =
  cborMap(
    (cbor("package"), cbor("lib")),
    (cbor("version"), cbor(version)),
    (cbor("modules"), cborArray()),
    (
      cbor("variants"),
      cborArray(
        variant(
          id,
          os,
          arch,
          cborMap(
            (cbor("id"), cbor("data")),
            (cbor("kind"), cbor("data")),
            (cbor("path"), cbor("data/lib.bin")),
            (cbor("hash"), cbor(blake3(binary))),
          ),
        )
      ),
    ),
  )

proc packed(
    v: CborValue, kid: string, key: SecretKey, variants: openArray[string]
): seq[byte] =
  let m = decodeManifest(encodeCbor(v)).get
  let cose = signManifest(m, b(kid), key).get
  var dirs: seq[(string, seq[(string, seq[byte])])]
  for id in variants:
    let path = if m.package == "app": "lib/app.so" else: "data/lib.bin"
    dirs.add((id, @[(path, binary)]))
  writeLgx(m.encoded, cose, dirs).get

proc verified(v: CborValue): VerifiedPackage =
  let m = decodeManifest(encodeCbor(v)).get
  VerifiedPackage(
    manifest: m, commitment: m.commitment.get, signer: anchors.anchor(b("good")).get
  )

suite "pkg.catalog: inspection records (PM §6)":
  test "[PKG-0185] [PKG-0187] [PKG-0333] an inspection record reports the verified manifest and its commitment":
    let v = verified(appManifest())
    let src = source("app", "1.0.0")
    let r = inspectRecord(v, src)
    let value = r.toCbor
    let back = decodeInspectRecord(decodeCbor(encodeCbor(value)).get)
    check back.isOk
    check back.get.commitment == v.commitment
    check back.get.signer == goodPub
    check back.get.source == src
    # [SPEC PM §11] Requested permissions stay manifest data: the record holds
    # the declaration as signed, and nothing else derives from it.
    check back.get.manifest.value == v.manifest.value
    check back.get.manifest.modules[0].requestedPermissions.len == 1
    # A commitment that is not the manifest value's is refused.
    var tampered = value
    var c = v.commitment
    c.valueRoot[0] = c.valueRoot[0] xor 1
    for e in tampered.entries.mitems:
      if e.key.getText == Opt.some("manifest_commitment"):
        e.value = c.toCbor
    check decodeInspectRecord(tampered).isErr
    var invalidManifest = value
    for e in invalidManifest.entries.mitems:
      if e.key.getText == Opt.some("manifest"):
        e.value.entries.keepItIf(it.key.getText != Opt.some("variants"))
    check decodeInspectRecord(invalidManifest).isErr

  test "[PKG-0331] [PKG-0501] a record's dependencies are its manifest's, whatever its modules require or its variant":
    let v = verified(appManifest())
    let i = inspection(v, v.manifest.modules)
    check i.kind == ikEligible
    check i.identity == ident("app@1.0.0")
    check i.dependencies == @[dep("lib ^1.0.0")]
    check v.manifest.modules[0].requires.len == 1
    check v.manifest.variants.len == 2

# Resolution ---------------------------------------------------------------------------

suite "pkg.resolver: dependency resolution (PM §11)":
  test "[PKG-0299] [PKG-0300] [PKG-0301] [PKG-0302] [PKG-0303] [PKG-0304] protected policy supplies four positive limits":
    proc limitSet(skip = "", value = cbor(5), extra = false): CborValue =
      result = cborMap()
      for k in ResolverLimitKeys:
        if k != skip:
          result.entries.add((cbor(k), value))
      if extra:
        result.entries.add((cbor("unbounded"), cbor(true)))

    let l = decodeResolverLimits(limitSet())
    check l.isOk
    check (l.get.names, l.get.depth, l.get.candidates, l.get.attempts) == (5, 5, 5, 5)
    for k in ResolverLimitKeys:
      check decodeResolverLimits(limitSet(skip = k)).isErr
    check decodeResolverLimits(limitSet(value = cbor(0))).isErr
    check decodeResolverLimits(limitSet(value = cbor(-1))).isErr
    check decodeResolverLimits(limitSet(value = cbor("5"))).isErr
    check decodeResolverLimits(limitSet(extra = true)).isErr
    check decodeResolverLimits(cborArray()).isErr
    check decodeResolverLimits(limitSet(value = cbor(high(uint64)))).isErr
    check resolverLimits(1, 1, 1, 1).isOk
    check resolverLimits(1, 0, 1, 1).isErr
    check resolverLimits(1, 1, 1, -3).isErr

  test "[PKG-0305] only protected policy sets a resolver limit":
    # The limits are read-only and travel only in ResolverInput: no root
    # reference, catalog entry, source, inspection or installed record has one.
    var l = limits()
    check not compiles(l.names = 1)
    check not compiles(ResolverLimits(names: 1))
    check not compiles(RootReference().limits)
    check not compiles(CatalogEntry().limits)
    check not compiles(PackageSource(kind: skLgx).limits)
    check not compiles(Inspection(kind: ikEligible).limits)
    check not compiles(InstalledPackage().limits)

  test "[PKG-0306] [PKG-0309] the closure-size and depth limits are checked before adding a name or inspecting deeper":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0", "B ^1.0.0"])
    u.add("A", "1.0.0", ["C ^1.0.0"])
    u.add("B", "1.0.0")
    u.add("C", "1.0.0", ["D ^1.0.0"])
    u.add("D", "1.0.0")
    let ok = u.resolveName("R", lim = limits(names = 5, depth = 3))
    check ok.picked == @["A@1.0.0", "B@1.0.0", "C@1.0.0", "D@1.0.0", "R@1.0.0"]
    check (ok.counters.names, ok.counters.depth) == (5, 3)
    check ok.chosen("D").depth == 3
    let names = u.resolveName("R", lim = limits(names = 4, depth = 3))
    check names.code == "dependency-unavailable"
    check names.counters.names == 4
    let deep = u.resolveName("R", lim = limits(names = 5, depth = 2))
    check deep.code == "dependency-unavailable"
    check "D@1.0.0#0" notin u.log # never inspected at depth 3
    check resolverLimits(1, 1, 1, 1).isOk
    let only = Universe()
    only.add("R", "1.0.0")
    check only.resolveName(
      "R", lim = limits(names = 1, depth = 1, candidates = 1, attempts = 1)
    ).picked == @["R@1.0.0"]

  test "[PKG-0307] candidates are considered in order, never beyond the per-name limit":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.3.0", ["X =1.0.0"])
    u.add("A", "1.2.0", ["X =1.0.0"])
    u.add("A", "1.1.0")
    let ok = u.resolveName("R", lim = limits(candidates = 3))
    check ok.picked == @["A@1.1.0", "R@1.0.0"]
    check ok.considered("A") == 3
    let over = u.resolveName("R", lim = limits(candidates = 2))
    check over.code == "dependency-unavailable"
    check over.considered("A") == 2
    check "A@1.1.0#0" notin u.log # nothing past the limit is examined
    # More versions than the limit do not fail a closure the examined ones give.
    let v = Universe()
    v.add("R", "1.0.0", ["A ^1.0.0"])
    v.add("A", "1.3.0")
    v.add("A", "1.2.0")
    v.add("A", "1.1.0")
    check v.resolveName("R", lim = limits(candidates = 1)).picked ==
      @["A@1.3.0", "R@1.0.0"]
    check "A@1.2.0#0" notin v.log

  test "[PKG-0308] every assignment attempt counts, and the count never decreases on backtracking":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0", "B ^1.0.0"])
    u.add("A", "1.1.0", ["C =2.0.0"])
    u.add("A", "1.0.0")
    u.add("B", "1.0.0", ["C =1.0.0"])
    u.add("C", "2.0.0")
    u.add("C", "1.0.0")
    let ok = u.resolveName("R")
    check ok.picked == @["A@1.0.0", "B@1.0.0", "C@1.0.0", "R@1.0.0"]
    # R, A@1.1.0, B@1.0.0, then back to A@1.0.0, B@1.0.0 again, C@1.0.0.
    check ok.counters.attempts == 6
    check ok.considered("A") == 2
    check ok.considered("B") == 1 # bound twice, charged once
    check ok.considered("R") == 1
    check u.log == @["R@1.0.0#0", "A@1.1.0#0", "B@1.0.0#0", "A@1.0.0#0", "C@1.0.0#0"]
    check u.resolveName("R", lim = limits(attempts = 6)).code == "ok"
    let short = u.resolveName("R", lim = limits(attempts = 5))
    check short.code == "dependency-unavailable"
    check short.counters.attempts == 5

  test "[PKG-0310] [PKG-0311] [PKG-0319] resolution changes nothing, and its outcome and counters depend only on its inputs":
    let u = Universe()
    const n = 2000
    proc p(i: int): string =
      "p" & align($i, 4, '0')

    for i in 0 ..< n:
      if i + 1 < n:
        u.add(p(i), "1.0.0", [p(i + 1) & " ^1.0.0"])
      else:
        u.add(p(i), "1.0.0")
    u.install("q", "1.0.0")
    let before = u.installed
    let a = u.resolveName(p(0), lim = limits(names = n, depth = n - 1))
    let b2 = u.resolveName(p(0), lim = limits(names = n, depth = n - 1))
    check a.code == "ok"
    check a.res.get.packages.len == n
    check a.picked == b2.picked
    check a.counters == b2.counters
    check a.counters.depth == n - 1
    let f1 = u.resolveName(p(0), lim = limits(names = n, depth = n - 2))
    let f2 = u.resolveName(p(0), lim = limits(names = n, depth = n - 2))
    check f1.code == "dependency-unavailable"
    check f1.res.error.msg == f2.res.error.msg
    check f1.counters == f2.counters
    check u.installed == before

  test "[PKG-0312] [PKG-0327] [PKG-0328] the closure is transitive, with one exact edge per direct dependency in declaration order":
    let u = Universe()
    u.add("R", "1.0.0", ["Z ^1.0.0", "A ^1.0.0"])
    u.add("Z", "1.4.0", ["A ^1.0.0"])
    u.add("A", "1.0.0")
    let o = u.resolveName("R")
    check o.picked == @["A@1.0.0", "R@1.0.0", "Z@1.4.0"]
    check o.res.get.root == ident("R@1.0.0")
    check o.chosen("R").resolvedDependencies ==
      @[
        ResolvedDependency(identity: ident("Z@1.4.0"), commitment: commitOf("Z@1.4.0")),
        ResolvedDependency(identity: ident("A@1.0.0"), commitment: commitOf("A@1.0.0")),
      ]
    check o.chosen("Z").resolvedDependencies.mapIt($it.identity) == @["A@1.0.0"]
    check o.chosen("A").resolvedDependencies.len == 0
    check o.chosen("Z").source == Opt.some(source("Z", "1.4.0"))

  test "[PKG-0313] [PKG-0330] a closure selects one version per name; separate closures may differ":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0", "B ^1.0.0"])
    u.add("A", "1.0.0", ["C ^1.0.0"])
    u.add("B", "1.0.0", ["C =1.1.0"])
    u.add("C", "1.2.0")
    u.add("C", "1.1.0")
    u.add("S", "1.0.0", ["C ^1.0.0"])
    check u.resolveName("R").picked == @["A@1.0.0", "B@1.0.0", "C@1.1.0", "R@1.0.0"]
    check u.resolveName("S").picked == @["C@1.2.0", "S@1.0.0"]

  test "[PKG-0315] [PKG-0600] [TXT-0481] [TXT-0482] an ineligible record is examined in order, charged like any other, and excluded before assignment":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.5.0", outcome = ikIneligible)
    u.add("A", "1.0.0")
    let o = u.resolveName("R", lim = limits(candidates = 2))
    check o.picked == @["A@1.0.0", "R@1.0.0"]
    check o.considered("A") == 2
    check o.counters.attempts == 2 # the root and A@1.0.0: A@1.5.0 is never bound
    check u.log == @["R@1.0.0#0", "A@1.5.0#0", "A@1.0.0#0"]
    let short = u.resolveName("R", lim = limits(candidates = 1))
    check short.code == "dependency-unavailable"
    check short.considered("A") == 1
    check "A@1.0.0#0" notin u.log

  test "[PKG-0316] [PKG-0476] [PKG-0583] a real LGX record is a candidate only when its signer is authorized for its exact name":
    var archives: Table[seq[byte], seq[byte]]
    var u = Universe()
    proc put(name, version: string, n: int, data: seq[byte]) =
      let s = source(name, version, n)
      u.catalog.add(CatalogEntry(identity: ident(name & "@" & version), source: s))
      archives[s.encoded] = data

    let lib100 = packed(libManifest("1.0.0"), "good", goodKey, ["linux-x86_64"])
    put(
      "app",
      "1.0.0",
      0,
      packed(appManifest(), "good", goodKey, ["linux-x86_64", "darwin-aarch64"]),
    )
    # Signed by an anchor that may sign "app" but not "lib".
    put(
      "lib",
      "1.1.0",
      0,
      packed(libManifest("1.1.0"), "rogue", rogueKey, ["linux-x86_64"]),
    )
    # A catalog entry's text establishes nothing: this archive is lib 1.0.0.
    put("lib", "1.2.0", 0, lib100)
    put("lib", "1.0.0", 0, lib100)
    put("lib", "1.0.0", 1, lib100)
    let fetched = archives
    let fetch: Fetch = proc(s: PackageSource): Opt[seq[byte]] {.gcsafe, raises: [].} =
      let k = s.encoded
      if k in fetched:
        Opt.some(fetched.getOrDefault(k))
      else:
        Opt.none(seq[byte])
    let inspect = lgxInspector(fetch, linuxHost, pathRules = PathRules())
    var c: ResolverCounters
    let r = resolve(
      ResolverInput(
        catalog: u.catalog,
        limits: limits(candidates = 3), # the two ineligible records are charged
        trust: anchors,
        inspect: inspect,
        retained: intact,
      ),
      RootReference(package: Opt.some("app")),
      c,
    )
    check r.isOk
    if r.isOk:
      check r.get.packages.mapIt($it.identity) == @["app@1.0.0", "lib@1.0.0"]
      check r.get.packages[1].source == Opt.some(source("lib", "1.0.0", 0))
    check c.considered == @[("app", 1), ("lib", 3)]
    check inspect(source("lib", "1.1.0"), anchors).kind == ikIneligible
    check inspect(source("lib", "1.1.0"), anchors).error.code == pecSignature
    check inspect(source("lib", "1.2.0"), anchors).kind == ikEligible
    check inspect(source("lib", "1.2.0"), anchors).identity == ident("lib@1.0.0")
    check inspect(PackageSource(kind: skNix, flakeRef: "x"), anchors).error.code ==
      pecUnsupportedSource
    check inspect(source("lib", "9.9.9"), anchors).kind == ikUnavailable

  test "[PKG-0584] [TXT-0465] packages signed per platform are distinct candidates; the host's platform picks one":
    # One identity, published as two separately signed single-variant
    # packages (PM l.959-961): their manifest commitments differ, and only the
    # one compatible with the host is eligible, so no commitment conflict
    # arises (G74 counts eligible candidates).
    var archives: Table[seq[byte], seq[byte]]
    var u = Universe()
    proc put(name, version: string, n: int, data: seq[byte]) =
      let s = source(name, version, n)
      u.catalog.add(CatalogEntry(identity: ident(name & "@" & version), source: s))
      archives[s.encoded] = data

    put(
      "lib",
      "1.0.0",
      0,
      packed(
        libManifest("1.0.0", "darwin-aarch64", "darwin", "aarch64"),
        "good",
        goodKey,
        ["darwin-aarch64"],
      ),
    )
    put(
      "lib", "1.0.0", 1, packed(libManifest("1.0.0"), "good", goodKey, ["linux-x86_64"])
    )
    let fetched = archives
    let fetch: Fetch = proc(s: PackageSource): Opt[seq[byte]] {.gcsafe, raises: [].} =
      let k = s.encoded
      if k in fetched:
        Opt.some(fetched.getOrDefault(k))
      else:
        Opt.none(seq[byte])
    let darwinHost = Platform(os: "darwin", architecture: "aarch64")
    for (host, n) in [(linuxHost, 1), (darwinHost, 0)]:
      let inspect = lgxInspector(fetch, host, pathRules = PathRules())
      var c: ResolverCounters
      let r = resolve(
        ResolverInput(
          catalog: u.catalog,
          limits: limits(),
          trust: anchors,
          inspect: inspect,
          retained: intact,
        ),
        RootReference(package: Opt.some("lib")),
        c,
      )
      check r.isOk
      if r.isOk:
        check r.get.packages.mapIt($it.identity) == @["lib@1.0.0"]
        check r.get.packages[0].source == Opt.some(source("lib", "1.0.0", n))
      check inspect(source("lib", "1.0.0", 1 - n), anchors).error.code ==
        pecIncompatiblePlatform

  test "[TXT-0473] [IMPL-DECISION I110] a real LGX record provides what its selected variant's module declarations provide (RG-7)":
    proc commitmentWith(fill: byte): CborValue =
      var root = newSeq[byte](32)
      root[0] = fill
      cborMap(
        (cbor("commitment_model"), cbor(CommitmentModelId)),
        (cbor("schema_root"), cbor(root)),
        (cbor("hash_profile"), cbor(HashProfileId)),
        (cbor("hash_suite"), cbor(HashSuiteId)),
      )

    let k = commitmentWith(7)
    proc art(id, path: string): CborValue =
      cborMap(
        (cbor("id"), cbor(id)),
        (cbor("kind"), cbor("module-binary")),
        (cbor("path"), cbor(path)),
        (cbor("hash"), cbor(blake3(binary))),
      )

    # lib 1.0.0 in two variants, one module each: only the darwin-aarch64
    # module implements K.
    let lib = cborMap(
      (cbor("package"), cbor("lib")),
      (cbor("version"), cbor("1.0.0")),
      (
        cbor("modules"),
        cborArray(
          cborMap(
            (cbor("module"), cbor("lib_darwin")),
            (cbor("artifact"), cbor("bin-darwin")),
            (cbor("implements"), cborArray(k)),
          ),
          cborMap(
            (cbor("module"), cbor("lib_linux")), (cbor("artifact"), cbor("bin-linux"))
          ),
        ),
      ),
      (
        cbor("variants"),
        cborArray(
          variant(
            "darwin-aarch64", "darwin", "aarch64", art("bin-darwin", "lib/darwin.so")
          ),
          variant("linux-x86_64", "linux", "x86_64", art("bin-linux", "lib/linux.so")),
        ),
      ),
    )
    let app = appManifest() # its dependency on lib lists K
    for e in app.entries.mitems:
      if e.key.getText == Opt.some("dependencies"):
        e.value.items[0].entries.add((cbor("contracts"), cborArray(k)))
    proc sign(v: CborValue, dirs: seq[(string, seq[(string, seq[byte])])]): seq[byte] =
      let m = decodeManifest(encodeCbor(v)).get
      writeLgx(m.encoded, signManifest(m, b("good"), goodKey).get, dirs).get

    var archives: Table[seq[byte], seq[byte]]
    var u = Universe()
    for (name, data) in [
      (
        "app",
        sign(
          app,
          @[
            ("linux-x86_64", @[("lib/app.so", binary)]),
            ("darwin-aarch64", @[("lib/app.so", binary)]),
          ],
        ),
      ),
      (
        "lib",
        sign(
          lib,
          @[
            ("darwin-aarch64", @[("lib/darwin.so", binary)]),
            ("linux-x86_64", @[("lib/linux.so", binary)]),
          ],
        ),
      ),
    ]:
      let s = source(name, "1.0.0")
      u.catalog.add(CatalogEntry(identity: ident(name & "@1.0.0"), source: s))
      archives[s.encoded] = data
    let fetched = archives
    let fetch: Fetch = proc(s: PackageSource): Opt[seq[byte]] {.gcsafe, raises: [].} =
      let k = s.encoded
      if k in fetched:
        Opt.some(fetched.getOrDefault(k))
      else:
        Opt.none(seq[byte])
    let darwinHost = Platform(os: "darwin", architecture: "aarch64")
    for (host, outcome) in [(darwinHost, "ok"), (linuxHost, "dependency-unavailable")]:
      let inspect = lgxInspector(fetch, host, pathRules = PathRules())
      let r = resolve(
        ResolverInput(
          catalog: u.catalog,
          limits: limits(),
          trust: anchors,
          inspect: inspect,
          retained: intact,
        ),
        RootReference(package: Opt.some("app")),
      )
      check (if r.isOk: "ok" else: $r.error.code) == outcome
      let i = inspect(source("lib", "1.0.0"), anchors)
      check i.kind == ikEligible
      check i.provides.len == (if host == darwinHost: 1 else: 0)

  test "[PKG-0318] an installed record satisfies a dependency without being materialized":
    let u = Universe()
    u.add("R", "1.0.0", ["C ^1.0.0"])
    u.install("C", "1.0.0")
    let o = u.resolveName("R")
    check o.picked == @["C@1.0.0", "R@1.0.0"]
    check o.chosen("C").installed
    check o.chosen("C").source.isNone
    check u.log == @["R@1.0.0#0"]

  test "[PKG-0259] [PKG-0320] [PKG-0321] [PKG-0606] the root is the highest available normal release unless a version or source fixes it; a source that conflicts with it is an invalid package":
    let u = Universe()
    u.add("R", "2.0.0-rc.1")
    u.add("R", "1.4.0", outcome = ikIneligible)
    u.add("R", "1.3.0")
    u.add("R", "1.2.0")
    u.add("S", "1.0.0-beta")
    check u.resolveName("R").picked == @["R@1.3.0"]
    check u.resolveName("R", "2.0.0-rc.1").picked == @["R@2.0.0-rc.1"]
    check u.resolveName("R", "1.4.0").code == "signature-verification-failed"
    check u.resolveName("S").code == "package-unavailable"
    check u.resolveName("S", "1.0.0-beta").picked == @["S@1.0.0-beta"]
    check u.resolveName("nope").code == "package-unavailable"
    check u.resolveName("R", "1.0.0").code == "package-unavailable"
    let bySource = RootReference(source: Opt.some(source("R", "1.2.0")))
    check u.resolveRoot(bySource).picked == @["R@1.2.0"]
    var named = bySource
    named.package = Opt.some("R")
    check u.resolveRoot(named).picked == @["R@1.2.0"]
    named.version = Opt.some("1.3.0")
    check u.resolveRoot(named).code == "invalid-package" # PKG-0259
    named.package = Opt.some("Q")
    named.version = Opt.none(string)
    check u.resolveRoot(named).code == "invalid-package"
    check u.resolveRoot(RootReference()).code == "invalid-request"
    check u.resolveRoot(
      RootReference(version: Opt.some("1.3.0"), source: bySource.source)
    ).code == "invalid-request"
    check u.resolveName("R", "v1.3.0").code == "invalid-request"
    check u.resolveRoot(RootReference(source: Opt.some(source("R", "9.0.0")))).code ==
      "package-unavailable"

  test "[PKG-0322] the unresolved name first in UTF-8 byte order is chosen first":
    let u = Universe()
    u.add("R", "1.0.0", ["b ^1.0.0", "é ^1.0.0", "B ^1.0.0", "a ^1.0.0"])
    for name in ["b", "é", "B", "a"]:
      u.add(name, "1.0.0")
    check u.resolveName("R").code == "ok"
    check u.log == @["R@1.0.0#0", "B@1.0.0#0", "a@1.0.0#0", "b@1.0.0#0", "é@1.0.0#0"]

  test "[PKG-0323] [PKG-0324] [PKG-0504] candidates go in descending SemVer precedence, backtracking to lower ones":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.9.0")
    u.add("A", "1.10.0")
    u.add("A", "1.2.0")
    u.add("A", "2.0.0")
    u.add("A", "1.11.0-rc.1")
    check u.resolveName("R").picked == @["A@1.10.0", "R@1.0.0"]
    let v = Universe()
    v.add("R", "1.0.0", ["A ^1.0.0"])
    v.add("A", "1.10.0", ["X ^1.0.0"])
    v.add("A", "1.9.0")
    check v.resolveName("R").picked == @["A@1.9.0", "R@1.0.0"]
    check v.log == @["R@1.0.0#0", "A@1.10.0#0", "A@1.9.0#0"]

  test "[PKG-0325] [IMPL-DECISION G74] two commitments for one identity fail without protected catalog policy":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.1.0", n = 0)
    u.add("A", "1.1.0", seed = "other", n = 1)
    u.add("A", "1.0.0")
    check u.resolveName("R").code == "dependency-unavailable"

  test "[PKG-0326] [PKG-0332] with no complete closure, or no catalog and no installed record, resolution fails":
    let u = Universe()
    u.add("R", "1.0.0", ["M ^1.0.0"])
    check u.resolveName("R").code == "dependency-unavailable"
    u.add("M", "2.0.0")
    check u.resolveName("R").code == "dependency-unavailable"
    # No catalog source for C: only an installed record can satisfy it.
    let v = Universe()
    v.add("R", "1.0.0", ["C ^1.0.0"])
    check v.resolveName("R").code == "dependency-unavailable"
    v.install("C", "1.1.0")
    check v.resolveName("R").picked == @["C@1.1.0", "R@1.0.0"]

  test "[PKG-0329] [PKG-0511] [TXT-0484] [TXT-0485] [TXT-0487] [IMPL-DECISION G167] an installed dependency keeps its recorded edges":
    let u = Universe()
    u.install("C", "1.0.0")
    u.install("B", "1.0.0", ["C ^1.0.0"], edges = ["C@1.0.0"])
    u.add("B", "1.0.0", ["C ^1.0.0"], n = 1) # the same package from another source
    u.add("C", "1.1.0")
    u.add("C", "1.0.0")
    u.add("R", "1.0.0", ["B ^1.0.0"])
    u.add("S", "1.0.0", ["C ^1.0.0"])
    let o = u.resolveName("R")
    check o.picked == @["B@1.0.0", "C@1.0.0", "R@1.0.0"]
    check o.chosen("B").installed
    check o.chosen("B").resolvedDependencies ==
      @[ResolvedDependency(identity: ident("C@1.0.0"), commitment: commitOf("C@1.0.0"))]
    check o.chosen("C").installed
    # The recorded edge is an exact requirement: C@1.1.0 is never inspected,
    # considered or charged (re-resolving B and backtracking until its edges
    # match the record would charge it).
    check o.considered("C") == 1
    check "C@1.1.0#0" notin u.log
    # Nor must the newer C be obtainable, or be in the catalog at all.
    let w = Universe()
    w.install("C", "1.0.0")
    w.install("B", "1.0.0", ["C ^1.0.0"], edges = ["C@1.0.0"])
    w.add("C", "1.1.0", outcome = ikUnavailable)
    w.add("R", "1.0.0", ["B ^1.0.0"])
    check w.resolveName("R").picked == @["B@1.0.0", "C@1.0.0", "R@1.0.0"]
    # Without the installed B, the newer C is selected.
    check u.resolveName("S").picked == @["C@1.1.0", "S@1.0.0"]
    # A requirement the recorded edge cannot meet rejects the installed
    # candidate; resolution backtracks to another version.
    let v = Universe()
    v.install("C", "1.0.0")
    v.install("B", "1.2.0", ["C ^1.0.0"], edges = ["C@1.0.0"])
    v.add("B", "1.1.0", ["C ^1.1.0"])
    v.add("C", "1.1.0")
    v.add("R", "1.0.0", ["B ^1.0.0", "C ^1.1.0"])
    check v.resolveName("R").picked == @["B@1.1.0", "C@1.1.0", "R@1.0.0"]

  test "[PKG-0503] [PKG-0504] a partial closure with a cycle is rejected and resolution backtracks":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.2.0", ["A ^1.0.0"]) # itself
    u.add("A", "1.1.0", ["B ^1.0.0"])
    u.add("B", "1.1.0", ["A ^1.0.0"]) # back to A
    u.add("B", "1.0.0")
    check u.resolveName("R").picked == @["A@1.1.0", "B@1.0.0", "R@1.0.0"]
    let v = Universe()
    v.add("R", "1.0.0", ["A ^1.0.0"])
    v.add("A", "1.0.0", ["R ^1.0.0"]) # back to the root
    check v.resolveName("R").code == "dependency-unavailable"
    let w = Universe()
    w.add("R", "1.0.0", ["R ^1.0.0"])
    check w.resolveName("R").code == "dependency-unavailable"

  test "[PKG-0505] [PKG-0506] [PKG-0507] an installed identity with another commitment fails the operation, not the candidate":
    let u = Universe()
    u.install("A", "1.1.0", seed = "installed")
    u.add("A", "1.1.0")
    u.add("A", "1.0.0")
    u.add("R", "1.0.0", ["A ^1.0.0"])
    check u.resolveName("R").code == "dependency-unavailable"
    check "A@1.0.0#0" notin u.log
    # The root's own conflict is the operation's rule, not the resolver's.
    let v = Universe()
    v.install("R", "1.0.0", seed = "installed")
    v.add("R", "1.0.0")
    let o = v.resolveName("R", "1.0.0")
    check o.picked == @["R@1.0.0"]
    check o.chosen("R").commitment == commitOf("R@1.0.0")
    check not o.chosen("R").installed

  test "[PKG-0508] [PKG-0509] [PKG-0601] unavailable material fails with package-unavailable and is not skipped; material not reached is not required":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.1.0", outcome = ikUnavailable)
    u.add("A", "1.0.0")
    check u.resolveName("R").code == "package-unavailable"
    let v = Universe()
    v.add("R", "1.0.0", ["A ^1.0.0"])
    v.add("A", "1.1.0")
    v.add("A", "1.0.0", outcome = ikUnavailable)
    check v.resolveName("R").picked == @["A@1.1.0", "R@1.0.0"]
    check "A@1.0.0#0" notin v.log

  test "[PKG-0510] equivalent sources are selected by ascending deterministic-CBOR source encoding":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.0.0", n = 2)
    u.add("A", "1.0.0", n = 1)
    u.add("A", "1.0.0", n = 3)
    let o = u.resolveName("R")
    check o.chosen("A").source == Opt.some(source("A", "1.0.0", 1))
    check u.log == @["R@1.0.0#0", "A@1.0.0#1", "A@1.0.0#2", "A@1.0.0#3"]

  test "[PKG-0598] [IMPL-DECISION G361] a limit above its documented maximum is refused by both constructors":
    let m = MaxResolverLimits
    check (m.names, m.depth, m.candidates, m.attempts) == (4096, 4095, 4096, 1_048_576)
    check resolverLimits(m.names, m.depth, m.candidates, m.attempts).isOk
    check resolverLimits(m.names + 1, m.depth, m.candidates, m.attempts).isErr
    check resolverLimits(m.names, m.depth + 1, m.candidates, m.attempts).isErr
    check resolverLimits(m.names, m.depth, m.candidates + 1, m.attempts).isErr
    check resolverLimits(m.names, m.depth, m.candidates, m.attempts + 1).isErr
    proc limitSet(values: openArray[uint64]): CborValue =
      result = cborMap()
      for i, k in ResolverLimitKeys:
        result.entries.add((cbor(k), cbor(values[i])))

    # ResolverLimitKeys: attempts, candidates, depth, names.
    let most =
      [uint64(m.attempts), uint64(m.candidates), uint64(m.depth), uint64(m.names)]
    check decodeResolverLimits(limitSet(most)).isOk
    for i in 0 ..< most.len:
      var over = most
      over[i] += 1
      check decodeResolverLimits(limitSet(over)).isErr
      over[i] = high(uint64)
      check decodeResolverLimits(limitSet(over)).isErr
    # PKG-0597: the documented maxima are these constants.
    let doc = readRepoFile("docs/CONFORMANCE.md")
    for (key, value) in [
      ("partial_closure_names", "4,096"),
      ("dependency_depth", "4,095"),
      ("candidates_per_name", "4,096"),
      ("assignment_attempts", "1,048,576"),
    ]:
      check ("| `" & key & "` | " & value & " |") in doc

  test "[PKG-0598] [IMPL-DECISION G361] a chain of 4,096 names resolves at the maxima":
    let u = Universe()
    const n = 4096
    proc p(i: int): string =
      "p" & align($i, 4, '0')

    for i in 0 ..< n:
      if i + 1 < n:
        u.add(p(i), "1.0.0", [p(i + 1) & " ^1.0.0"])
      else:
        u.add(p(i), "1.0.0")
    let m = MaxResolverLimits
    let o = u.resolveName(
      p(0),
      lim = limits(
        names = m.names,
        depth = m.depth,
        candidates = m.candidates,
        attempts = m.attempts,
      ),
    )
    check o.code == "ok"
    check (o.counters.names, o.counters.depth, o.counters.attempts) == (n, n - 1, n)
    check o.chosen(p(n - 1)).depth == n - 1

  test "[TXT-0483] examining a root candidate is charged, and binding the root is an attempt":
    let u = Universe()
    u.add("R", "1.2.0", outcome = ikIneligible)
    u.add("R", "1.1.0", outcome = ikIneligible)
    u.add("R", "1.0.0")
    let o = u.resolveName("R")
    check o.picked == @["R@1.0.0"]
    check o.considered("R") == 3
    check o.counters.attempts == 1
    let short = u.resolveName("R", lim = limits(candidates = 2))
    check short.code == "dependency-unavailable"
    check short.considered("R") == 2
    check "R@1.0.0#0" notin u.log
    # A source fixes the root: charged once, after it is inspected. An
    # ineligible source has no identity to charge under.
    let bySource = u.resolveRoot(RootReference(source: Opt.some(source("R", "1.0.0"))))
    check bySource.considered("R") == 1
    let bad = u.resolveRoot(RootReference(source: Opt.some(source("R", "1.2.0"))))
    check bad.code == "signature-verification-failed"
    check bad.counters.considered.len == 0

  test "[TXT-0479] a name's depth is the greatest number of edges on any path from the root":
    # R -> A -> C, and R -> B -> D -> C: C is at depth 3, not 2.
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0", "B ^1.0.0"])
    u.add("A", "1.0.0", ["C ^1.0.0"])
    u.add("B", "1.0.0", ["D ^1.0.0"])
    u.add("D", "1.0.0", ["C ^1.0.0"])
    u.add("C", "1.0.0")
    let o = u.resolveName("R", lim = limits(depth = 3))
    check o.picked == @["A@1.0.0", "B@1.0.0", "C@1.0.0", "D@1.0.0", "R@1.0.0"]
    check o.chosen("C").depth == 3
    check o.counters.depth == 3
    check u.resolveName("R", lim = limits(depth = 2)).code == "dependency-unavailable"

  test "[PKG-0599] an edge that deepens a bound name checks the depth limit for it and for the names it requires":
    # C is bound at depth 2 and requires E (depth 3). Binding D adds D -> C,
    # which puts C at 3 and E, still unbound, at 4.
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0", "B ^1.0.0"])
    u.add("A", "1.0.0", ["C ^1.0.0"])
    u.add("B", "1.0.0", ["D ^1.0.0"])
    u.add("C", "1.0.0", ["E ^1.0.0"])
    u.add("D", "1.0.0", ["C ^1.0.0"])
    u.add("E", "1.0.0")
    let deep = u.resolveName("R", lim = limits(depth = 3))
    check deep.code == "dependency-unavailable" # it terminates: nothing is backtracked
    check "E@1.0.0#0" notin u.log
    check deep.counters.attempts == 5 # R, A, B, C, D
    let ok = u.resolveName("R", lim = limits(depth = 4))
    check ok.code == "ok"
    check (ok.chosen("C").depth, ok.chosen("E").depth) == (3, 4)

  test "[PKG-0592] [TXT-0476] [TXT-0478] a candidate provides every contract an accumulated requirement lists, or it is ineligible":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0 +K"])
    u.add("A", "1.2.0", provides = ["L"])
    u.add("A", "1.1.0", provides = ["K", "L"])
    let o = u.resolveName("R")
    check o.picked == @["A@1.1.0", "R@1.0.0"]
    check o.considered("A") == 2 # A@1.2.0 is examined and charged
    # TXT-0476: the version names no contract. A newer release that dropped K
    # is chosen when the dependency lists none (TXT-0478: the producer
    # obligation is not verified).
    let v = Universe()
    v.add("R", "1.0.0", ["A ^1.0.0"])
    v.add("A", "1.0.1")
    v.add("A", "1.0.0", provides = ["K"])
    check v.resolveName("R").picked == @["A@1.0.1", "R@1.0.0"]
    # A contract that arrives after the name is bound: B's requirement rejects
    # the bound A@1.2.0, and resolution backtracks.
    let w = Universe()
    w.add("R", "1.0.0", ["A ^1.0.0", "B ^1.0.0"])
    w.add("B", "1.0.0", ["A ^1.0.0 +K"])
    w.add("A", "1.2.0")
    w.add("A", "1.1.0", provides = ["K"])
    check w.resolveName("R").picked == @["A@1.1.0", "B@1.0.0", "R@1.0.0"]
    # An installed record provides what its retained declarations provide.
    let x = Universe()
    x.add("R", "1.0.0", ["A ^1.0.0 +K"])
    x.install("A", "1.1.0", provides = ["K"])
    x.install("A", "1.2.0")
    check x.resolveName("R").picked == @["A@1.1.0", "R@1.0.0"]

  test "[TXT-0475] an installed record naming an unsupported manifest schema is ineligible, and not an integrity failure":
    let u = Universe()
    u.add("R", "1.0.0", ["C ^1.0.0"])
    u.install("C", "1.1.0", supported = false)
    u.add("C", "1.0.0")
    u.altered.incl("C@1.1.0") # not judged: the record is ineligible first
    let o = u.resolveName("R")
    check o.picked == @["C@1.0.0", "R@1.0.0"]
    check o.considered("C") == 2
    check u.checked.len == 0
    check u.resolveName("C", "1.1.0").code == "unsupported-manifest"

  test "[PKG-0602] [PKG-0603] absent or altered retained bytes of a reached installed candidate fail the operation; the record is not skipped":
    let u = Universe()
    u.add("R", "1.0.0", ["C ^1.0.0"])
    u.install("C", "1.1.0")
    u.add("C", "1.0.0")
    u.altered.incl("C@1.1.0")
    let o = u.resolveName("R")
    check o.code == "artifact-integrity-failed"
    check u.checked == @["C@1.1.0"]
    check "C@1.0.0#0" notin u.log # not treated as ineligible: C@1.0.0 is not tried
    # A record that is not reached is not checked.
    let v = Universe()
    v.add("R", "1.0.0", ["C =1.0.0"])
    v.install("C", "1.1.0")
    v.add("C", "1.0.0")
    v.altered.incl("C@1.1.0")
    check v.resolveName("R").picked == @["C@1.0.0", "R@1.0.0"]
    check v.checked.len == 0
    # The installed root is checked the same way.
    check u.resolveName("C", "1.1.0").code == "artifact-integrity-failed"

  test "[IMPL-DECISION G166] an installed record whose retained signer is no longer accepted is ineligible":
    # The same commitment in the catalog under an accepted signer satisfies
    # the identity: it stays installed (B7).
    let u = Universe()
    u.add("R", "1.0.0", ["C ^1.0.0"])
    u.install("C", "1.1.0", withdrawn = true)
    u.add("C", "1.1.0")
    let o = u.resolveName("R")
    check o.picked == @["C@1.1.0", "R@1.0.0"]
    check o.chosen("C").installed
    # With no such record, the next version is tried.
    let v = Universe()
    v.add("R", "1.0.0", ["C ^1.0.0"])
    v.install("C", "1.1.0", withdrawn = true)
    v.add("C", "1.0.0")
    let p = v.resolveName("R")
    check p.picked == @["C@1.0.0", "R@1.0.0"]
    check p.considered("C") == 2
    # Another commitment in the catalog is a conflict, eligible or not.
    let w = Universe()
    w.add("R", "1.0.0", ["C ^1.0.0"])
    w.install("C", "1.1.0", withdrawn = true)
    w.add("C", "1.1.0", seed = "other")
    w.add("C", "1.0.0")
    check w.resolveName("R").code == "dependency-unavailable"
    # The installed root (Q9): an install by name whose catalog brings no
    # accepted signature fails; one that does re-installs it.
    let x = Universe()
    x.install("R", "1.0.0", withdrawn = true)
    check x.resolveName("R").code == "signature-verification-failed"
    x.add("R", "1.0.0")
    let y = x.resolveName("R")
    check y.picked == @["R@1.0.0"]
    check y.chosen("R").installed

  test "[TXT-0486] [IMPL-DECISION I110] a pinned version the catalog lists under another commitment is examined, charged and excluded":
    # B's recorded edge pins C@1.0.0 to the installed commitment; the catalog
    # lists C@1.0.0 with another. B sorts before C, so the pin is in place
    # when C is reached (Q8).
    let u = Universe()
    u.install("C", "1.0.0")
    u.install("B", "1.0.0", ["C ^1.0.0"], edges = ["C@1.0.0"])
    u.add("C", "1.0.0", seed = "other")
    u.add("R", "1.0.0", ["B ^1.0.0"])
    let o = u.resolveName("R")
    check o.picked == @["B@1.0.0", "C@1.0.0", "R@1.0.0"]
    check o.chosen("C").commitment == commitOf("C@1.0.0")
    check o.considered("C") == 1
    check "C@1.0.0#0" in u.log # its commitment was not known: examined
    # Reached before the pin exists, the same records conflict.
    let v = Universe()
    v.install("A", "1.0.0")
    v.install("Z", "1.0.0", ["A ^1.0.0"], edges = ["A@1.0.0"])
    v.add("A", "1.0.0", seed = "other")
    v.add("R", "1.0.0", ["A ^1.0.0", "Z ^1.0.0"])
    check v.resolveName("R").code == "dependency-unavailable"
    # A record whose commitment is known and excluded is neither considered
    # nor charged (TXT-0485).
    let w = Universe()
    w.install("C", "1.0.0")
    w.install("B", "1.0.0", ["C ^1.0.0"], edges = ["C@1.0.0/other"])
    w.add("R", "1.0.0", ["B ^1.0.0"])
    let x = w.resolveName("R")
    check x.code == "dependency-unavailable"
    check x.considered("C") == 0

  test "[PKG-0606] a root release whose closure cannot be resolved is not exchanged for a lower one":
    let u = Universe()
    u.add("R", "1.1.0", ["M ^1.0.0"])
    u.add("R", "1.0.0")
    check u.resolveName("R").code == "dependency-unavailable"
    check "R@1.0.0#0" notin u.log
    check u.resolveName("R", "1.0.0").picked == @["R@1.0.0"]

  test "[PKG-0593] [TXT-0474] a root whose every candidate is ineligible only for an unsupported schema fails unsupported-manifest":
    let u = Universe()
    u.add("R", "1.2.0", outcome = ikIneligible, code = pecUnsupportedManifest)
    u.add("R", "1.1.0", outcome = ikIneligible, code = pecUnsupportedManifest)
    check u.resolveName("R").code == "unsupported-manifest"
    check u.resolveName("R", "1.1.0").code == "unsupported-manifest"
    check u.resolveRoot(RootReference(source: Opt.some(source("R", "1.1.0")))).code ==
      "unsupported-manifest"
    u.install("S", "1.0.0", supported = false)
    check u.resolveName("S").code == "unsupported-manifest"
    # TXT-0474: as a dependency, such a candidate is excluded.
    u.add("T", "1.0.0", ["R ^1.0.0"])
    check u.resolveName("T").code == "dependency-unavailable"
    # Mixed reasons (Q6, the TF-60 interim): the first error in descending
    # order, the installed record's before the catalog's.
    let v = Universe()
    v.add("R", "1.2.0", outcome = ikIneligible, code = pecIncompatiblePlatform)
    v.add("R", "1.1.0", outcome = ikIneligible, code = pecUnsupportedManifest)
    check v.resolveName("R").code == "incompatible-platform"
    v.install("R", "1.2.0", supported = false)
    check v.resolveName("R").code == "unsupported-manifest"

  test "[PKG-0508] [IMPL-DECISION I110] every source of a reached identity is reached: an unavailable second source fails":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.0.0", n = 1)
    u.add("A", "1.0.0", n = 2, outcome = ikUnavailable)
    check u.resolveName("R").code == "package-unavailable"
    check u.log == @["R@1.0.0#0", "A@1.0.0#1", "A@1.0.0#2"]

  test "[TXT-0489] the retained source counts only while the catalog lists it, and the root keeps its selected source":
    proc rootSource(catalog: openArray[int]): (bool, Opt[PackageSource]) =
      let u = Universe()
      u.install("R", "1.0.0", n = 2)
      for n in catalog:
        u.add("R", "1.0.0", n = n)
      let o = u.resolveName("R")
      (o.chosen("R").installed, o.chosen("R").source)

    # Each result is bound before `check`: a tuple a nested proc returns, passed to
    # `check`'s inline iterator, is never destroyed under ARC/ORC (upstream draft 182).
    let retainedOnly = rootSource([2])
    check retainedOnly == (true, Opt.some(source("R", "1.0.0", 2)))
    let bothListed = rootSource([1, 2])
    check bothListed == (true, Opt.some(source("R", "1.0.0", 1)))
    let noneListed = rootSource([])
    check noneListed == (true, Opt.none(PackageSource))
    # An explicitly supplied source is kept too.
    let u = Universe()
    u.install("R", "1.0.0")
    u.add("R", "1.0.0", n = 3)
    let o = u.resolveRoot(RootReference(source: Opt.some(source("R", "1.0.0", 3))))
    check o.chosen("R").installed
    check o.chosen("R").source == Opt.some(source("R", "1.0.0", 3))

  test "[TXT-0496] an update selects the highest eligible newer release; a newer one with an unsupported schema is not applicable":
    let u = Universe()
    u.install("R", "1.0.0")
    u.add("R", "1.0.0")
    u.add("R", "2.0.0-rc.1")
    u.add("R", "1.2.0", outcome = ikIneligible, code = pecUnsupportedManifest)
    u.add("R", "1.1.0")
    let o = u.update("R@1.0.0")
    check o.picked == @["R@1.1.0"]
    check not o.res.get.unchanged
    check o.considered("R") == 2
    # Only an unsupported newer release: the update changes nothing.
    let v = Universe()
    v.install("R", "1.0.0")
    v.add("R", "1.1.0", outcome = ikIneligible, code = pecUnsupportedManifest)
    let same = v.update("R@1.0.0")
    check same.code == "ok"
    check same.res.get.unchanged
    check same.res.get.root == ident("R@1.0.0")
    check same.res.get.packages.len == 0
    check same.considered("R") == 1
    # Q7, the TF-60 interim: no newer release is eligible, and one is
    # ineligible for another reason. A dropped platform is that case.
    let w = Universe()
    w.install("R", "1.0.0")
    w.add("R", "1.2.0", outcome = ikIneligible, code = pecUnsupportedManifest)
    w.add("R", "1.1.0", outcome = ikIneligible, code = pecIncompatiblePlatform)
    check w.update("R@1.0.0").code == "incompatible-platform"
    # A fixed target: strictly newer, and PKG-0593 applies to it.
    check u.update("R@1.0.0", target = "1.0.0").code == "invalid-request"
    check u.update("R@1.0.0", target = "0.9.0").code == "invalid-request"
    check u.update("R@1.0.0", target = "1.2.0").code == "unsupported-manifest"
    check u.update("R@1.0.0", target = "1.1.0").picked == @["R@1.1.0"]
    check u.update("R@1.0.0", via = "R@1.1.0#0").picked == @["R@1.1.0"]
    check u.update("R@1.0.0", via = "R@1.0.0#0").code == "invalid-request"
    # A source that does not identify the selected target (PM l.1703, l.1074).
    check u.update("R@1.0.0", target = "1.1.0", via = "R@1.0.0#0").code ==
      "invalid-package"
    check u.update("R@0.5.0").code == "package-not-installed"
    var other =
      RootReference(package: Opt.some("S"), newerThan: Opt.some(ident("R@1.0.0")))
    check u.resolveRoot(other).code == "invalid-request"

  test "[IMPL-DECISION G166] an update that changes nothing fails while the retained signer is not accepted (TF-07)":
    let u = Universe()
    u.install("R", "1.0.0", withdrawn = true)
    check u.update("R@1.0.0").code == "signature-verification-failed"
    u.add("R", "1.1.0")
    check u.update("R@1.0.0").picked == @["R@1.1.0"]

  test "requirements: exact text, or a compatible normal release (PM §11)":
    check satisfies(rkCompatible, "1.2.3", "1.9.0")
    check not satisfies(rkCompatible, "1.2.3", "2.0.0")
    check not satisfies(rkCompatible, "1.2.3", "1.2.2")
    check not satisfies(rkCompatible, "1.2.3", "1.3.0-rc.1")
    check satisfies(rkCompatible, "0.2.3", "0.2.9")
    check not satisfies(rkCompatible, "0.2.3", "0.3.0")
    check satisfies(rkCompatible, "0.0.3", "0.0.3")
    check not satisfies(rkCompatible, "0.0.3", "0.0.4")
    check satisfies(rkCompatible, "0.0.0", "0.0.0")
    check not satisfies(rkCompatible, "0.0.0", "0.0.1")
    check satisfies(rkExact, "1.0.0-rc.1", "1.0.0-rc.1")
    check not satisfies(rkExact, "1.0.0", "1.0.0-rc.1")

# The frozen oracle (Tier 5 step 5-3c; DECISIONS G454) ---------------------------------

proc commitmentText(c: ManifestCommitment): string =
  toHex(encodeCbor(c.toCbor))

proc described(r: Result[Resolution, PackageError], c: ResolverCounters): seq[string] =
  ## Everything one resolution reports, a line per item, to compare two resolvers by.
  if r.isErr:
    result.add("error " & $r.error.code & ": " & r.error.msg)
  else:
    let s = r.get
    result.add("root " & $s.root & " unchanged=" & $s.unchanged)
    for p in s.packages:
      result.add(
        $p.identity & " " & commitmentText(p.commitment) & " installed=" & $p.installed &
          " source=" & (if p.source.isSome: toHex(p.source.get.encoded)
        else: "none") & " depth=" & $p.depth & " edges=" &
          p.resolvedDependencies
          .mapIt($it.identity & "/" & commitmentText(it.commitment))
          .join(",")
      )
    let k = s.counters
    result.add(
      "its counters " & $k.names & " " & $k.depth & " " & $k.considered & " " &
        $k.attempts & " " & k.limit
    )
  result.add(
    "counters names=" & $c.names & " depth=" & $c.depth & " considered=" & $c.considered &
      " attempts=" & $c.attempts & " limit=" & c.limit
  )

proc resolveBy(
    u: Universe, root: RootReference, lim: ResolverLimits, oracle: bool
): seq[string] =
  ## One resolution by the resolver or by the oracle: what it reports, then the sources it
  ## inspected and the installed records whose retained bytes it checked, in order.
  u.log.setLen(0)
  u.checked.setLen(0)
  var c: ResolverCounters
  let input = ResolverInput(
    installed: u.installed,
    catalog: u.catalog,
    limits: lim,
    trust: u.trust,
    inspect: u.inspector,
    retained: u.retained,
  )
  let r =
    if oracle:
      oracleResolve(input, root, c)
    else:
      resolve(input, root, c)
  result = described(r, c)
  result.add("inspected " & u.log.join(" "))
  result.add("checked " & u.checked.join(" "))

type
  Feature = enum
    gfIneligible = "an ineligible record"
    gfUnsupported = "a record with an unsupported schema"
    gfPlatform = "a record for another platform"
    gfUnavailable = "an unavailable record"
    gfClaims = "a record whose manifest names another identity"
    gfPrerelease = "a pre-release"
    gfExact = "an exact requirement"
    gfContracts = "a requirement listing a contract"
    gfProvides = "a record providing contracts"
    gfSelf = "a self-dependency"
    gfBackEdge = "a dependency on an earlier name (a possible cycle)"
    gfSources = "an identity with two equivalent sources"
    gfTwoCommitments = "an identity with two commitments (G74)"
    gfUnavailableSecond = "an identity whose second source is unavailable"
    gfInstalled = "an installed record"
    gfPinned = "an installed record with recorded edges"
    gfPinConflict = "a recorded edge naming another commitment"
    gfAltered = "an installed record with altered retained bytes"
    gfWithdrawn = "an installed record whose signer is withdrawn"
    gfB7 = "a withdrawn signer whose commitment the catalog lists (B7)"
    gfInstalledConflict =
      "an installed identity the catalog lists with another commitment"
    gfInstalledUnsupported = "an installed record with an unsupported schema"
    gfRetainedUnlisted =
      "an installed record whose retained source the catalog does not list"
    gfRootName = "a root by name"
    gfRootVersion = "a root by name and version"
    gfRootSource = "a root by source"
    gfRootSourceName = "a root by source and name"
    gfRootUpdate = "a root by update"
    gfRootUpdateTarget = "an update with a target version or source"
    gfSmallLimits = "small limits"

  Round = object
    u: Universe
    root: RootReference
    limits: ResolverLimits

const
  oracleNames = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]
  oracleVersions = ["0.1.0", "1.0.0", "1.1.0", "1.2.0-rc.1", "1.2.0", "2.0.0"]

proc anyVersion(rng: var Rand): string =
  oracleVersions[rng.rand(0 ..< oracleVersions.len)]

proc requirement(
    rng: var Rand, target: int, versionsOf: seq[seq[string]], seen: var set[Feature]
): string =
  ## Mostly a version the target has, so that most requirements can be met.
  let v =
    if rng.rand(0 .. 7) > 0:
      versionsOf[target][rng.rand(0 ..< versionsOf[target].len)]
    else:
      rng.anyVersion
  if '-' in v:
    seen.incl gfPrerelease
  if rng.rand(0 .. 4) == 0:
    seen.incl gfExact
    result = oracleNames[target] & " =" & v
  else:
    result = oracleNames[target] & " ^" & v
  if rng.rand(0 .. 11) == 0:
    seen.incl gfContracts
    result.add(if rng.rand(0 .. 1) == 0: " +x" else: " +y")

proc dependencies(
    rng: var Rand, self: int, versionsOf: seq[seq[string]], seen: var set[Feature]
): seq[string] =
  ## As a verified manifest has them: each name once, in name order (`manifest.nim`). Mostly one
  ## of the next three names, so closures grow deep; any name, an earlier one or itself, one time
  ## in ten.
  let n = versionsOf.len
  var targets: seq[int]
  for _ in 0 ..< (if self + 1 >= n: rng.rand(0 .. 2) else: rng.rand(1 .. 4)):
    let t =
      if rng.rand(1 .. 10) == 1 or self + 1 >= n:
        rng.rand(0 ..< n)
      else:
        rng.rand(self + 1 .. min(n - 1, self + 3))
    if t == self and rng.rand(0 .. 3) > 0:
      continue # a self-dependency, but rarely
    if t notin targets:
      targets.add(t)
  targets.sort()
  for t in targets:
    if t == self:
      seen.incl gfSelf
    elif t < self:
      seen.incl gfBackEdge
    result.add(rng.requirement(t, versionsOf, seen))

proc generated(rng: var Rand, seen: var set[Feature]): Round =
  ## One seeded catalog, installed state, root and limits.
  let u = Universe()
  let n = rng.rand(2 .. oracleNames.len)
  var versionsOf: seq[seq[string]]
  for i in 0 ..< n:
    var vs = @oracleVersions
    rng.shuffle(vs)
    versionsOf.add(vs[0 ..< rng.rand(1 .. vs.len)])
  var listed: seq[(int, string, seq[string], seq[string])]
    ## eligible records: name index, version, dependencies, provided contracts
  for i in 0 ..< n:
    let name = oracleNames[i]
    for v in versionsOf[i]:
      if '-' in v:
        seen.incl gfPrerelease
      let deps = rng.dependencies(i, versionsOf, seen)
      var provides: seq[string]
      case rng.rand(0 .. 3)
      of 0:
        provides = @["x"]
      of 1:
        provides = @["y"]
      of 2:
        provides = @["x", "y"]
      else:
        discard
      if provides.len > 0:
        seen.incl gfProvides
      case rng.rand(0 .. 119)
      of 0 .. 5:
        seen.incl gfIneligible
        u.add(name, v, deps, outcome = ikIneligible)
      of 6, 7:
        seen.incl gfUnsupported
        u.add(name, v, deps, outcome = ikIneligible, code = pecUnsupportedManifest)
      of 8, 9:
        seen.incl gfPlatform
        u.add(name, v, deps, outcome = ikIneligible, code = pecIncompatiblePlatform)
      of 10:
        seen.incl gfUnavailable
        u.add(name, v, deps, outcome = ikUnavailable)
      of 11:
        seen.incl gfClaims
        u.add(name, v, deps, claims = name & "@" & rng.anyVersion, provides = provides)
      else:
        u.add(name, v, deps, provides = provides)
        listed.add((i, v, deps, provides))
      case rng.rand(0 .. 59)
      of 0 .. 3:
        seen.incl gfSources
        u.add(name, v, deps, n = 1, provides = provides)
      of 4:
        seen.incl gfTwoCommitments
        u.add(name, v, deps, n = 1, seed = "other", provides = provides)
      of 5:
        seen.incl gfUnavailableSecond
        u.add(name, v, deps, n = 1, outcome = ikUnavailable)
      else:
        discard
  # Installed state: at most one record per name, its edges naming installed records where there
  # are some.
  type Kept = object
    name, version, seed: string
    deps, provides: seq[string]
    withdrawn, supported: bool
    n: int

  var kept: seq[Kept]
  if rng.rand(0 .. 1) == 0:
    seen.incl gfInstalled
    for _ in 0 ..< rng.rand(1 .. 4):
      var k = Kept(supported: true)
      var i: int
      if listed.len > 0 and rng.rand(0 .. 2) > 0:
        let l = listed[rng.rand(0 ..< listed.len)]
        i = l[0]
        k.version = l[1]
        k.deps = l[2]
        k.provides = l[3]
      else:
        i = rng.rand(0 ..< n)
        k.version = rng.anyVersion
        k.deps = rng.dependencies(i, versionsOf, seen)
      k.name = oracleNames[i]
      if kept.anyIt(it.name == k.name):
        continue
      case rng.rand(0 .. 15)
      of 0, 1:
        seen.incl gfInstalledConflict
        k.seed = "installed"
      of 2, 3:
        seen.incl gfWithdrawn
        k.withdrawn = true
        if listed.anyIt(oracleNames[it[0]] == k.name and it[1] == k.version):
          seen.incl gfB7
      of 4:
        seen.incl gfInstalledUnsupported
        k.supported = false
      else:
        discard
      if rng.rand(0 .. 4) == 0:
        seen.incl gfRetainedUnlisted
        k.n = 2
      kept.add(k)
  for k in kept:
    var edges: seq[string]
    if k.deps.len > 0 and rng.rand(0 .. 3) > 0:
      seen.incl gfPinned
      for d in k.deps:
        let target = d.split(' ')[0]
        var e = ""
        for t in kept:
          if t.name == target:
            e = t.name & "@" & t.version & (if t.seed.len > 0: "/" & t.seed
            else: "")
        if e.len == 0:
          e = target & "@" & rng.anyVersion
        if rng.rand(0 .. 7) == 0:
          seen.incl gfPinConflict
          e = e.split('/')[0] & "/other"
        edges.add(e)
    u.install(
      k.name,
      k.version,
      k.deps,
      edges,
      seed = k.seed,
      provides = k.provides,
      withdrawn = k.withdrawn,
      supported = k.supported,
      n = k.n,
    )
    if rng.rand(0 .. 5) == 0:
      seen.incl gfAltered
      u.altered.incl(k.name & "@" & k.version)
  # The root.
  var root: RootReference
  let pick = rng.rand(0 .. 15)
  if pick >= 13 and kept.len > 0:
    seen.incl gfRootUpdate
    let k = kept[rng.rand(0 ..< kept.len)]
    root.newerThan = Opt.some(PackageIdentity(package: k.name, version: k.version))
    if rng.rand(0 .. 3) == 0:
      seen.incl gfRootUpdateTarget
      root.version = Opt.some(rng.anyVersion)
    if rng.rand(0 .. 3) == 0:
      seen.incl gfRootUpdateTarget
      root.source = Opt.some(source(k.name, rng.anyVersion, rng.rand(0 .. 1)))
  elif pick >= 10:
    # Mostly a source the catalog lists.
    seen.incl gfRootSource
    let i = rng.rand(0 ..< n)
    let name = oracleNames[i]
    if rng.rand(0 .. 3) > 0:
      let e = u.catalog[rng.rand(0 ..< u.catalog.len)]
      root.source = Opt.some(e.source)
      root.package = Opt.some(e.identity.package)
    else:
      root.source = Opt.some(source(name, rng.anyVersion, rng.rand(0 .. 2)))
      root.package = Opt.some(name)
    if rng.rand(0 .. 1) == 0:
      root.package = Opt.none(string)
    else:
      seen.incl gfRootSourceName
      if rng.rand(0 .. 5) == 0:
        root.package = Opt.some(oracleNames[rng.rand(0 ..< n)])
  else:
    seen.incl gfRootName
    let i =
      if rng.rand(0 .. 3) > 0:
        rng.rand(0 .. min(2, n - 1))
      else:
        rng.rand(0 ..< n)
    root.package = Opt.some(oracleNames[i])
    if rng.rand(0 .. 3) == 0:
      seen.incl gfRootVersion
      root.version = Opt.some(
        if rng.rand(0 .. 3) > 0:
          versionsOf[i][rng.rand(0 ..< versionsOf[i].len)]
        else:
          rng.anyVersion
      )
  let lim =
    if rng.rand(0 .. 2) == 0:
      limits()
    else:
      seen.incl gfSmallLimits
      limits(
        names = rng.rand(1 .. 14),
        depth = rng.rand(1 .. 12),
        candidates = rng.rand(1 .. 6),
        attempts = rng.rand(1 .. 24),
      )
  Round(u: u, root: root, limits: lim)

proc dagRound(rng: var Rand): Round =
  ## A seeded acyclic catalog for the depth bookkeeping: names required only by names of a lower
  ## rank, a random order other than the names', so a name bound early is often required later
  ## by a deeper one, which deepens it and what it requires. Some requirements no version meets
  ## (`=2.0.0`), found only at the target's frame, so the search backtracks over binds that
  ## deepened names, and their other versions require other names.
  let u = Universe()
  let n = rng.rand(5 .. oracleNames.len)
  var rank: seq[int]
  for i in 0 ..< n:
    rank.add(i)
  rng.shuffle(rank)
  const series = ["1.0.0", "1.1.0", "1.2.0", "1.3.0"]
  var versionsOf: seq[seq[string]]
  for i in 0 ..< n:
    var vs = @series
    rng.shuffle(vs)
    versionsOf.add(vs[0 ..< rng.rand(1 .. vs.len)])
  for i in 0 ..< n:
    var higher: seq[int]
    for j in 0 ..< n:
      if rank[j] > rank[i]:
        higher.add(j)
    for v in versionsOf[i]:
      var targets: seq[int]
      if higher.len > 0:
        for _ in 0 ..< rng.rand(1 .. 3):
          let t = higher[rng.rand(0 ..< higher.len)]
          if t notin targets:
            targets.add(t)
      targets.sort()
      var deps: seq[string]
      for t in targets:
        let name = oracleNames[t]
        deps.add(
          case rng.rand(0 .. 9)
          of 0:
            name & " =2.0.0"
          of 1, 2:
            name & " =" & versionsOf[t][rng.rand(0 ..< versionsOf[t].len)]
          else:
            name & " ^1.0.0"
        )
      u.add(oracleNames[i], v, deps)
  let lim =
    if rng.rand(0 .. 3) > 0:
      limits()
    else:
      limits(
        names = rng.rand(2 .. 12),
        depth = rng.rand(1 .. 6),
        candidates = rng.rand(1 .. 4),
        attempts = rng.rand(2 .. 60),
      )
  Round(
    u: u, root: RootReference(package: Opt.some(oracleNames[rank.find(0)])), limits: lim
  )

suite "pkg.resolver: the resolver gives the frozen oracle's results (G454)":
  test "[IMPL-DECISION G454] seeded catalogs: the same outcome, closure, counters, inspections and retained checks":
    # The oracle is the resolver as 5-3b-2 built it (`tests/support/oracle_resolver.nim`).
    var rng = initRand(0x5_3C_1)
    var seen: set[Feature]
    var outcomes: CountTable[string]
    for round in 0 ..< 2_000:
      let g = rng.generated(seen)
      checkpoint "round " & $round
      let want = g.u.resolveBy(g.root, g.limits, oracle = true)
      let got = g.u.resolveBy(g.root, g.limits, oracle = false)
      check got == want
      outcomes.inc(want[0].split(':')[0] & " / " & want[^3].split("limit=")[1])
    checkpoint $outcomes
    # Every feature occurs in some round, and so does every limit and the outcomes they lead to.
    for f in Feature:
      checkpoint $f
      check f in seen
    var keys: seq[string]
    for k, _ in outcomes:
      keys.add(k)
    for want in [
      "root", "error dependency-unavailable", "error package-unavailable",
      "error artifact-integrity-failed", "error unsupported-manifest",
      "error signature-verification-failed", "error incompatible-platform",
      "error invalid-package",
    ]:
      checkpoint want
      check keys.anyIt(it.startsWith(want & " "))
    for limit in [
      "partial_closure_names", "dependency_depth", "candidates_per_name",
      "assignment_attempts",
    ]:
      checkpoint limit
      check keys.anyIt(it.endsWith("/ " & limit))

  test "[IMPL-DECISION G454] seeded acyclic catalogs: names deepened by later binds, and backtracking over those binds":
    var rng = initRand(0x5_3C_1_DA6)
    var outcomes: CountTable[string]
    for round in 0 ..< 1_000:
      let g = rng.dagRound
      checkpoint "round " & $round
      let want = g.u.resolveBy(g.root, g.limits, oracle = true)
      let got = g.u.resolveBy(g.root, g.limits, oracle = false)
      check got == want
      outcomes.inc(want[0].split(' ')[0] & " / " & want[^3].split("limit=")[1])
    checkpoint $outcomes
    var keys: seq[string]
    for k, _ in outcomes:
      keys.add(k)
    for want in ["root / ", "error / "]:
      checkpoint want
      check keys.anyIt(it == want)
    for limit in [
      "partial_closure_names", "dependency_depth", "candidates_per_name",
      "assignment_attempts",
    ]:
      checkpoint limit
      check keys.anyIt(it.endsWith("/ " & limit))

  test "[IMPL-DECISION G454] the bench's shapes, at the preset and at the maxima: the same outcome, closure and counters":
    # `lift` binds and gives up names that deepen names bound before them.
    let preset = resolverLimits(
      int64(PresetPartialClosureNames),
      int64(PresetDependencyDepth),
      int64(PresetCandidatesPerName),
      int64(PresetAssignmentAttempts),
    ).get
    for (name, size, parameter) in [
      ("dense", 64, 0),
      ("chain", 256, 0),
      ("hub", 64, 4),
      ("layered", 128, 16),
      ("wide", 2_000, 6),
      ("lift", 64, 4),
    ]:
      let s = shapeOf(name, size, parameter).get
      for lim in [preset, MaxResolverLimits]:
        checkpoint name & " " & $size & " limits " & $lim.names & "/" & $lim.depth & "/" &
          $lim.candidates & "/" & $lim.attempts
        var c, k: ResolverCounters
        let input = s.inputOf(lim)
        let want = described(oracleResolve(input, s.rootOf, k), k)
        let got = described(resolve(input, s.rootOf, c), c)
        check got == want

# The resumable run (Tier 5 step 5-3c-2; DECISIONS G455) --------------------------------

proc runBy(
    u: Universe,
    root: RootReference,
    lim: ResolverLimits,
    budget: int64,
    work, turns, releaseTurns: var int64,
): seq[string] =
  ## [G455] One resolution as a resumable run of `budget` work units a turn, each need
  ## answered when the run asks for it, as the driver does, then released turn by turn:
  ## what `resolveBy` reports.
  u.log.setLen(0)
  u.checked.setLen(0)
  let input = ResolverInput(
    installed: u.installed,
    catalog: u.catalog,
    limits: lim,
    trust: u.trust,
    inspect: u.inspector,
    retained: u.retained,
  )
  let run = startRun(input, root, budget)
  turns = 0
  while true:
    var s = run.resume()
    case s.kind
    of suNeedSource:
      run.supply(s.source, input.inspect(s.source, input.trust))
    of suNeedRetained:
      run.supplyRetained(s.record, input.retained(input.installed[s.record]))
    of suTurn:
      inc turns
    of suDone:
      work = run.work
      result = described(s.outcome, run.counters)
      break
  releaseTurns = 1
  while not run.release():
    inc releaseTurns
  result.add("inspected " & u.log.join(" "))
  result.add("checked " & u.checked.join(" "))

suite "pkg.resolver: the resumable run (G455)":
  const Budgets = [1'i64, 2, 3, 17, 1_000, NoTurnBudget]

  test "[IMPL-DECISION G455] seeded catalogs, under turn budgets of 1, 2, 3, 17 and 1,000 work units and none: the oracle's results, and one work total":
    # The same retrievals in the same order as the oracle's synchronous run, whatever the
    # budget; the work total and the turns are the same each time for one budget.
    var rng = initRand(0x5_3C_2)
    var seen: set[Feature]
    var sliced, releasedInTurns = 0
    for round in 0 ..< 2_000:
      let g = rng.generated(seen)
      checkpoint "round " & $round
      let want = g.u.resolveBy(g.root, g.limits, oracle = true)
      var total = -1'i64
      var most = 0'i64
      for budget in Budgets:
        checkpoint "budget " & $budget
        var work, turns, releaseTurns: int64
        check g.u.runBy(g.root, g.limits, budget, work, turns, releaseTurns) == want
        if total < 0:
          total = work
          most = turns
        check work == total
        check turns <= most
        if budget == NoTurnBudget:
          check turns == 0
          check releaseTurns == 1
        if budget == 1:
          if work > 0:
            check turns > 0
            inc sliced
          if releaseTurns > 1:
            inc releasedInTurns
        if budget == 17:
          var work2, turns2, releaseTurns2: int64
          check g.u.runBy(g.root, g.limits, budget, work2, turns2, releaseTurns2) == want
          check work2 == work
          check turns2 == turns
          check releaseTurns2 == releaseTurns
    check sliced > 1_000
    check releasedInTurns > 1_000

  test "[IMPL-DECISION G455] a run is resumed only until its outcome; what it holds is released after it, or instead of it":
    let u = Universe()
    u.add("a", "1.0.0", ["b ^1.0.0"])
    u.add("b", "1.0.0")
    let input = ResolverInput(
      catalog: u.catalog,
      limits: MaxResolverLimits,
      trust: u.trust,
      inspect: u.inspector,
      retained: u.retained,
    )
    let root = RootReference(package: Opt.some("a"))
    # Given up after its first need: no later answer reaches it.
    let given = startRun(input, root, 1)
    var first = given.resume()
    while first.kind == suTurn: # the setup's turns
      first = given.resume()
    check first.kind == suNeedSource
    var releases = 1
    while not given.release():
      inc releases
    check releases > 1
    given.supply(first.source, input.inspect(first.source, input.trust))
    check given.supplied == 0
    # Driven to its outcome: the same as the synchronous run's.
    let run = startRun(input, root, 1)
    var outcome: Result[Resolution, PackageError]
    while true:
      var s = run.resume()
      case s.kind
      of suNeedSource:
        run.supply(s.source, input.inspect(s.source, input.trust))
      of suNeedRetained:
        run.supplyRetained(s.record, input.retained(input.installed[s.record]))
      of suTurn:
        discard
      of suDone:
        outcome = s.outcome
        break
    check outcome.get.packages.mapIt($it.identity) == @["a@1.0.0", "b@1.0.0"]
    check resolve(input, root).get.packages.mapIt($it.identity) ==
      @["a@1.0.0", "b@1.0.0"]
    while not run.release():
      discard

# The operation bound (Tier 5 step 5-3c; DECISIONS G477) ---------------------------------

proc boundedBy(
    u: Universe,
    root: RootReference,
    lim: ResolverLimits,
    bound: Opt[int],
    budget = NoTurnBudget,
    counters: var ResolverCounters,
): seq[string] =
  ## [G477] One resolution as a run under the operation bound `bound`: what `resolveBy`
  ## reports, and the run's counters.
  u.log.setLen(0)
  u.checked.setLen(0)
  let input = ResolverInput(
    installed: u.installed,
    catalog: u.catalog,
    limits: lim,
    trust: u.trust,
    inspect: u.inspector,
    retained: u.retained,
    operationEntries: bound,
  )
  let run = startRun(input, root, budget)
  while true:
    var s = run.resume()
    case s.kind
    of suNeedSource:
      run.supply(s.source, input.inspect(s.source, input.trust))
    of suNeedRetained:
      run.supplyRetained(s.record, input.retained(input.installed[s.record]))
    of suTurn:
      discard
    of suDone:
      counters = run.counters
      result = described(s.outcome, run.counters)
      break
  while not run.release():
    discard
  result.add("inspected " & u.log.join(" "))
  result.add("checked " & u.checked.join(" "))

func isPrefixOf(a, b: seq[string]): bool =
  a.len <= b.len and a == b[0 ..< a.len]

suite "pkg.resolver: the operation bound (G477)":
  test "[IMPL-DECISION G477] the inputs read: each record once, with its dependency entries and provided contracts, an installed one's counted before its retained bytes are asked for":
    let u = Universe()
    u.add("a", "1.0.0", ["b ^1.0.0", "c ^1.0.0"], provides = ["x"]) # 1 + 2 + 1
    u.add("b", "1.1.0", outcome = ikIneligible) # 1
    u.add("b", "1.0.0") # 1
    u.install("c", "1.0.0", provides = ["y", "z"]) # 1 + 0 + 2
    let root = RootReference(package: Opt.some("a"))
    let lim = limits()
    var c: ResolverCounters
    let want = u.boundedBy(root, lim, Opt.none(int), counters = c)
    check want[0] == "root a@1.0.0 unchanged=false"
    check c.entries == 9
    check c.bound == ""
    check want[^2] == "inspected a@1.0.0#0 b@1.1.0#0 b@1.0.0#0"
    check want[^1] == "checked c@1.0.0"
    # The same count whatever the budget: an evaluation that waits for the retained bytes
    # is made again, and the record is counted once.
    for budget in [1'i64, 3, NoTurnBudget]:
      checkpoint "budget " & $budget
      check u.boundedBy(root, lim, Opt.none(int), budget, c) == want
      check c.entries == 9
      check u.boundedBy(root, lim, Opt.some(9), budget, c) == want
      check c.bound == ""
      # Each stop is at the record whose inputs pass the bound, which is read and no more.
      for (bound, inspected, checked) in [
        (8, "a@1.0.0#0 b@1.1.0#0 b@1.0.0#0", ""),
        (5, "a@1.0.0#0 b@1.1.0#0 b@1.0.0#0", ""),
        (4, "a@1.0.0#0 b@1.1.0#0", ""),
        (3, "a@1.0.0#0", ""),
        (1, "a@1.0.0#0", ""),
      ]:
        checkpoint "bound " & $bound
        let got = u.boundedBy(root, lim, Opt.some(bound), budget, c)
        check got[0] ==
          "error package-unavailable: the operation reads more package records and entries than this deployment allows"
        check $bound notin got[0]
        check got[^2] == "inspected " & inspected
        check got[^1] == "checked " & checked
        check c.bound == "operation_entries"
        check c.limit == ""
        check c.entries > bound

  test "[IMPL-DECISION G477] a source root is counted once, when its inspection is supplied":
    let u = Universe()
    u.add("a", "1.0.0", ["b ^1.0.0"]) # 1 + 1
    u.add("b", "1.0.0") # 1
    let root = RootReference(source: Opt.some(source("a", "1.0.0")))
    var c: ResolverCounters
    let want = u.boundedBy(root, limits(), Opt.none(int), counters = c)
    check want[0] == "root a@1.0.0 unchanged=false"
    check c.entries == 3
    check u.boundedBy(root, limits(), Opt.some(3), counters = c) == want
    check u.boundedBy(root, limits(), Opt.some(2), counters = c)[0].startsWith(
      "error package-unavailable"
    )
    check c.bound == "operation_entries"

  test "[IMPL-DECISION G477] seeded catalogs: at the inputs a run reads, the bound changes nothing; below them, the run ends package-unavailable after a prefix of the same retrievals, its counters no further than the unbounded run's":
    var rng = initRand(0x5_3C_2_B0)
    var seen: set[Feature]
    var stopped = 0
    for round in 0 ..< 1_000:
      let g = rng.generated(seen)
      checkpoint "round " & $round
      var k: ResolverCounters
      let want = g.u.boundedBy(g.root, g.limits, Opt.none(int), counters = k)
      check want == g.u.resolveBy(g.root, g.limits, oracle = true)
      check k.bound == ""
      if k.entries == 0:
        continue
      var c: ResolverCounters
      for budget in [1'i64, NoTurnBudget]:
        checkpoint "budget " & $budget
        check g.u.boundedBy(g.root, g.limits, Opt.some(k.entries), budget, c) == want
        check c == k
      if k.entries == 1:
        continue
      for bound in [k.entries - 1, rng.rand(1 .. k.entries - 1)]:
        checkpoint "bound " & $bound
        let got = g.u.boundedBy(g.root, g.limits, Opt.some(bound), counters = c)
        check got[0].startsWith("error package-unavailable: the operation reads more")
        check c.bound == "operation_entries"
        check c.limit == ""
        check c.entries > bound
        check c.entries <= k.entries
        check c.names <= k.names
        check c.depth <= k.depth
        check c.attempts <= k.attempts
        check got[^2].splitWhitespace.isPrefixOf(want[^2].splitWhitespace)
        check got[^1].splitWhitespace.isPrefixOf(want[^1].splitWhitespace)
        inc stopped
        # A budget of one unit stops at the same place.
        check g.u.boundedBy(g.root, g.limits, Opt.some(bound), 1, c) == got
    check stopped > 500
