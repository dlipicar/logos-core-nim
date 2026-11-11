## PM §5, §6, §11: catalog entries, source and inspection records, and
## dependency resolution. The resolver tests use a synthetic catalog whose
## inspector answers from a table (commitments are opaque to resolution) and
## logs every source it is asked about; one test resolves real signed LGX
## packages through `lgxInspector`.

import std/[sequtils, strutils, tables]
import unittest2
import ../src/logos_core/[cbor, pins]
import ../src/logos_core/crypto/[blake3, slhdsa]
import ../src/logos_core/package/[lgx, resolver, signing, trust]

proc b(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

proc str(s: seq[byte]): string =
  for c in s:
    result.add(char(c))

proc commitOf(seed: string): ManifestCommitment =
  ManifestCommitment(
    commitmentModel: CommitmentModelId,
    schemaRoot: blake3(b("schema")),
    schemaSubtreeRoot: blake3(b("subtree")),
    valueRoot: blake3(b(seed)),
    hashProfile: HashProfileId,
    hashSuite: HashSuiteId,
  )

proc ident(s: string): PackageIdentity =
  let at = s.find('@')
  PackageIdentity(package: s[0 ..< at], version: s[at + 1 .. ^1])

proc dep(s: string): PackageDependency =
  ## "name ^min" (compatible) or "name =version" (exact).
  let parts = s.split(' ')
  PackageDependency(
    package: parts[0],
    kind: if parts[1][0] == '=': rkExact else: rkCompatible,
    version: parts[1][1 .. ^1],
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
) =
  ## A catalog entry for name@version and what inspecting its source yields.
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
      )
    of ikIneligible:
      Inspection(
        kind: ikIneligible,
        error: packageError(pecSignature, "test: no accepted anchor signed it"),
      )
    of ikUnavailable:
      Inspection(kind: ikUnavailable, reason: "test: the source is unreachable")

proc install(
    u: Universe,
    name, version: string,
    deps: openArray[string] = [],
    edges: openArray[string] = [],
    seed = "",
) =
  ## An installed record; its recorded edges name installed identities.
  u.installed.add(
    InstalledPackage(
      identity: PackageIdentity(package: name, version: version),
      commitment: commitOf(name & "@" & version & seed),
      dependencies: deps.mapIt(dep(it)),
      resolvedDependencies:
        edges.mapIt(ResolvedDependency(identity: ident(it), commitment: commitOf(it))),
    )
  )

proc inspector(u: Universe): Inspector =
  let outcomes = u.outcomes
  result = proc(s: PackageSource): Inspection {.gcsafe, raises: [].} =
    u.log.add(str(s.objectLocator))
    outcomes.getOrDefault(
      s.encoded, Inspection(kind: ikUnavailable, reason: "test: no such source")
    )

proc limits(
    names = 100, depth = 100, candidates = 100, attempts = 10_000
): ResolverLimits =
  resolverLimits(names, depth, candidates, attempts).get

proc resolveRoot(u: Universe, root: RootReference, lim = limits()): Outcome =
  u.log.setLen(0)
  var c: ResolverCounters
  let input = ResolverInput(
    installed: u.installed, catalog: u.catalog, limits: lim, inspect: u.inspector
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

proc libManifest(version: string): CborValue =
  cborMap(
    (cbor("package"), cbor("lib")),
    (cbor("version"), cbor(version)),
    (cbor("modules"), cborArray()),
    (
      cbor("variants"),
      cborArray(
        variant(
          "linux-x86_64",
          "linux",
          "x86_64",
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
    let i = inspection(v)
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
    check decodeResolverLimits(limitSet(value = cbor(high(uint64)))).isOk
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

  test "[PKG-0315] [PKG-0317] an ineligible record is excluded before ordering and never charged":
    let u = Universe()
    u.add("R", "1.0.0", ["A ^1.0.0"])
    u.add("A", "1.5.0", outcome = ikIneligible)
    u.add("A", "1.0.0")
    let o = u.resolveName("R", lim = limits(candidates = 1))
    check o.picked == @["A@1.0.0", "R@1.0.0"]
    check o.considered("A") == 1

  test "[PKG-0316] [PKG-0476] a real LGX record is a candidate only when its signer is authorized for its exact name":
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
    let inspect = lgxInspector(fetch, anchors, linuxHost, pathRules = PathRules())
    var c: ResolverCounters
    let r = resolve(
      ResolverInput(
        catalog: u.catalog, limits: limits(candidates = 1), inspect: inspect
      ),
      RootReference(package: Opt.some("app")),
      c,
    )
    check r.isOk
    if r.isOk:
      check r.get.packages.mapIt($it.identity) == @["app@1.0.0", "lib@1.0.0"]
      check r.get.packages[1].source == Opt.some(source("lib", "1.0.0", 0))
    check inspect(source("lib", "1.1.0")).kind == ikIneligible
    check inspect(source("lib", "1.1.0")).error.code == pecSignature
    check inspect(source("lib", "1.2.0")).kind == ikEligible
    check inspect(source("lib", "1.2.0")).identity == ident("lib@1.0.0")
    check inspect(PackageSource(kind: skNix, flakeRef: "x")).error.code ==
      pecUnsupportedSource
    check inspect(source("lib", "9.9.9")).kind == ikUnavailable

  test "[PKG-0318] an installed record satisfies a dependency without being materialized":
    let u = Universe()
    u.add("R", "1.0.0", ["C ^1.0.0"])
    u.install("C", "1.0.0")
    let o = u.resolveName("R")
    check o.picked == @["C@1.0.0", "R@1.0.0"]
    check o.chosen("C").installed
    check o.chosen("C").source.isNone
    check u.log == @["R@1.0.0#0"]

  test "[PKG-0320] [PKG-0321] the root is the highest available normal release unless a version or source fixes it":
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
    check u.resolveRoot(named).code == "invalid-request"
    named.package = Opt.some("Q")
    named.version = Opt.none(string)
    check u.resolveRoot(named).code == "invalid-request"
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

  test "[PKG-0329] [PKG-0511] [IMPL-DECISION G167] an installed dependency keeps its recorded edges":
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

  test "[PKG-0508] [PKG-0509] unavailable material fails with package-unavailable and is not skipped":
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
