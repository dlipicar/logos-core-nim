## The resolution driver and the engine's resolution (Tier 5 step 5-3b;
## DECISIONS G405; docs/PACKAGE-MANAGER.md §4). First the driver against one
## synchronous resolver run, over synthetic catalogs whose inspections come
## from a table (commitments are opaque to resolution); then the engine over
## real signed LGX archives served by a scripted provider.

import std/[sequtils, strutils, tables]
import unittest2
import logos_sdk/pins
import logos_sdk/base/hex
import ../src/logos_core/pins as core_pins
import ../src/logos_core/package/[errors, resolver]
import ./support/[pmfixture, pmworld]

# Synthetic catalogs -----------------------------------------------------------------

proc digestOf(h: string): typeof(ManifestCommitment().schemaRoot) =
  let bytes = hex.fromHex(h).get
  for i in 0 ..< result.len:
    result[i] = bytes[i]

proc commitOf(seed: string): ManifestCommitment =
  ManifestCommitment(
    commitmentModel: CommitmentModelId,
    schemaRoot: digestOf(core_pins.PackageManifestSchemaRoot),
    schemaSubtreeRoot: digestOf(core_pins.PackageManifestSubtreeRoot),
    valueRoot: blake3(bytesOf(seed)),
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

type Universe = ref object
  catalog: seq[CatalogEntry]
  outcomes: Table[seq[byte], Inspection]

proc add(
    u: Universe,
    name, version: string,
    deps: openArray[string] = [],
    outcome = ikEligible,
    claims = "",
    n = 0,
) =
  let s = PackageSource(
    kind: skLgx,
    storage: "main",
    objectLocator: bytesOf(name & "@" & version & "#" & $n),
  )
  u.catalog.add(CatalogEntry(identity: ident(name & "@" & version), source: s))
  u.outcomes[s.encoded] =
    case outcome
    of ikEligible:
      Inspection(
        kind: ikEligible,
        identity: ident(
          if claims.len > 0:
            claims
          else:
            name & "@" & version
        ),
        commitment: commitOf(name & "@" & version & "#" & $n),
        dependencies: deps.mapIt(dep(it)),
      )
    of ikIneligible:
      Inspection(kind: ikIneligible, error: packageError(pecSignature, "not signed"))
    of ikUnavailable:
      Inspection(kind: ikUnavailable, reason: "absent")

proc root(name: string, version = ""): RootReference =
  RootReference(
    package: Opt.some(name),
    version:
      if version.len > 0:
        Opt.some(version)
      else:
        Opt.none(string),
  )

proc summary(r: Result[Resolution, PackageError]): string =
  if r.isErr:
    return "error " & $r.error.code
  for p in r.get.packages:
    result.add($p.identity & "/" & $p.commitment.valueRoot.toHex[0 .. 7] & " ")

proc scenarios(): seq[(string, Universe, RootReference)] =
  block:
    let u = Universe()
    u.add("app", "1.0.0", ["lib ^1.0.0"])
    u.add("lib", "1.0.0")
    result.add(("a direct dependency", u, root("app")))
  block:
    let u = Universe()
    u.add("app", "1.0.0", ["lib ^1.0.0", "other ^1.0.0"])
    u.add("lib", "1.2.0", ["zed =9.0.0"])
    u.add("lib", "1.1.0")
    u.add("other", "1.0.0")
    result.add(("backtracking past a missing dependency", u, root("app")))
  block:
    let u = Universe()
    u.add("app", "1.0.0", ["lib ^1.0.0"])
    u.add("lib", "1.3.0", outcome = ikIneligible)
    u.add("lib", "1.2.0", outcome = ikUnavailable)
    u.add("lib", "1.1.0")
    result.add(("ineligible and unavailable records", u, root("app")))
  block:
    let u = Universe()
    u.add("app", "1.0.0", ["a ^1.0.0", "b ^1.0.0"])
    u.add("a", "1.0.0", ["c =1.0.0"])
    u.add("b", "1.0.0", ["c =2.0.0"])
    u.add("c", "1.0.0")
    u.add("c", "2.0.0")
    result.add(("a conflict", u, root("app")))
  block:
    let u = Universe()
    u.add("app", "1.0.0", ["lib ^1.0.0"])
    u.add("lib", "1.5.0", claims = "lib@1.0.0")
    u.add("lib", "1.0.0")
    result.add(("an entry whose archive is another version", u, root("app")))
  block:
    let u = Universe()
    u.add("a", "1.0.0", ["b ^1.0.0"])
    u.add("b", "1.0.0", ["c ^1.0.0"])
    u.add("c", "1.0.0", ["d ^1.0.0"])
    u.add("d", "1.0.0")
    u.add("d", "1.1.0")
    result.add(("a chain", u, root("a")))
  block:
    let u = Universe()
    u.add("app", "2.0.0")
    u.add("app", "1.0.0", ["lib ^1.0.0"])
    u.add("lib", "1.0.0")
    result.add(("an exact root version", u, root("app", "1.0.0")))
  block:
    let u = Universe()
    u.add("lib", "1.0.0")
    result.add(("an absent root", u, root("app")))
  block:
    let u = Universe()
    u.add("app", "1.0.0", ["lib ^1.0.0"])
    u.add("lib", "1.0.0", outcome = ikUnavailable)
    result.add(("only unavailable material", u, root("app")))

suite "resolution driver (G405)":
  test "[PKG-0019] [PKG-0069] the driver equals one synchronous resolver run with every inspection given up front":
    for (name, u, r) in scenarios():
      var asked: seq[string]
      let outcomes = u.outcomes
      let inspect: Inspector = proc(
          source: PackageSource, trust: TrustInput
      ): Inspection {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          asked.add(textOf(source.objectLocator))
        outcomes.getOrDefault(source.encoded)
      var counters: ResolverCounters
      let direct = resolve(
        ResolverInput(
          catalog: u.catalog,
          limits: MaxResolverLimits,
          inspect: inspect,
          retained: proc(
              p: InstalledPackage
          ): Result[void, string] {.gcsafe, raises: [].} =
            err("none"),
        ),
        r,
        counters,
      )
      var retrieved: seq[string]
      let d = initDriver(u.catalog, TrustInput(), MaxResolverLimits, r)
      let driven = d.drive(
        proc(source: PackageSource): Inspection {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            retrieved.add(textOf(source.objectLocator))
          outcomes.getOrDefault(source.encoded)
      )
      checkpoint name
      check driven.summary == direct.summary
      check retrieved == asked
      check d.counters == counters
      check d.runs == retrieved.len + 1

  test "an unreached candidate is never retrieved":
    let u = Universe()
    u.add("app", "1.0.0", ["lib ^1.0.0"])
    u.add("lib", "1.2.0")
    u.add("lib", "1.1.0")
    u.add("lib", "1.0.0")
    u.add("zed", "1.0.0")
    var retrieved: seq[string]
    let outcomes = u.outcomes
    let r = initDriver(u.catalog, TrustInput(), MaxResolverLimits, root("app")).drive(
        proc(source: PackageSource): Inspection {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            retrieved.add(textOf(source.objectLocator))
          outcomes.getOrDefault(source.encoded)
      )
    check r.isOk
    check retrieved == @["app@1.0.0#0", "lib@1.2.0#0"]

  test "a nix source is unsupported and never retrieved":
    var catalog = @[
      CatalogEntry(
        identity: ident("app@1.0.0"),
        source: PackageSource(kind: skNix, flakeRef: "github:logos-co/app"),
      )
    ]
    var retrieved = 0
    let r = initDriver(catalog, TrustInput(), MaxResolverLimits, root("app")).drive(
        proc(source: PackageSource): Inspection {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            inc retrieved
          Inspection(kind: ikUnavailable, reason: "x")
      )
    check r.isErr
    check retrieved == 0

# The engine over signed archives ----------------------------------------------------

let (orgKey, orgPub) = testKey(1)
let (rogueKey, _) = testKey(2)

# Built once: each signature takes about a second.
let app100 = packed(dataManifest("app", "1.0.0", [("lib", "1.0.0")]), "org", orgKey)
let lib120 = packed(dataManifest("lib", "1.2.0"), "org", orgKey)
let lib100 = packed(dataManifest("lib", "1.0.0"), "org", orgKey)
let rogue130 = packed(dataManifest("lib", "1.3.0"), "org", rogueKey)
let platLinux = packed(
  dataManifest("plat", "2.0.0", variants = [("linux-x86_64", "linux", "x86_64")]),
  "org",
  orgKey,
)
let platDarwin = packed(
  dataManifest("plat", "2.0.0", variants = [("darwin-aarch64", "darwin", "aarch64")]),
  "org",
  orgKey,
)

let orgTrust = trustOf([anchorOf("org", ["app", "lib", "plat"], orgPub)]).trustBytes

type Scene = object
  w: World
  objects: Table[seq[byte], seq[byte]]
  calls: seq[Command]

proc scene(entries: openArray[(CatalogEntry, seq[byte])], trust = orgTrust): Scene =
  ## The engine with `entries` as its kept, matching catalog and each archive
  ## (an empty one is absent) served under the entry's locator.
  var cat: seq[CatalogEntry]
  for (e, archive) in entries:
    cat.add(e)
    if archive.len > 0:
      result.objects[e.source.objectLocator] = archive
  let doc = catalogBytes(cat)
  result.objects[bytesOf("catalog")] = doc
  result.w = newWorld(doc, kept = keptFor(doc), trust = trust)
  result.w.emit(result.w.e.start())
  result.w.bringUp()
  result.w.serve(result.objects, result.calls)
  result.calls.setLen(0)

proc resolveIn(s: var Scene, r: RootReference): Result[Resolution, PackageError] =
  let id = uint64(s.w.replies.len + 1)
  s.w.emit(s.w.e.resolve(id, r))
  s.w.serve(s.objects, s.calls)
  doAssert s.w.replies.len == int(id)
  s.w.replies[^1].outcome

proc statted(s: Scene): seq[string] =
  for c in s.calls:
    if c.kind == cmStat:
      result.add(textOf(c.locator))

suite "engine resolution over signed archives (G405)":
  test "the closure resolves, and an unreached candidate is never retrieved":
    var s = scene(
      [
        (entryOf("app", "1.0.0"), app100),
        (entryOf("lib", "1.2.0"), lib120),
        (entryOf("lib", "1.0.0"), lib100),
      ]
    )
    let r = s.resolveIn(root("app"))
    check r.isOk
    check r.get.packages.mapIt($it.identity) == @["app@1.0.0", "lib@1.2.0"]
    check s.statted == @["app@1.0.0", "lib@1.2.0"]
    check s.w.e.cache.counters.opened == 2

  test "a second operation answers from the verification cache, still retrieving each archive":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    check s.resolveIn(root("app")).isOk
    check s.resolveIn(root("app")).isOk
    check s.w.e.cache.counters.opened == 2
    check s.w.e.cache.counters.hits == 2
    check s.statted == @["app@1.0.0", "lib@1.0.0", "app@1.0.0", "lib@1.0.0"]

  test "unavailable material is package-unavailable, never ineligible":
    var s = scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), @[])])
    let r = s.resolveIn(root("app"))
    check r.isErr
    check r.error.code == pecPackageUnavailable
    check s.w.e.cache.counters.opened == 1

  test "per-platform archives for one identity: the compatible one is selected (C7)":
    var s = scene(
      [
        (entryOf("plat", "2.0.0", locator = "plat-darwin"), platDarwin),
        (entryOf("plat", "2.0.0", locator = "plat-linux0"), platLinux),
      ]
    )
    let r = s.resolveIn(root("plat"))
    check r.isOk
    check r.get.packages.len == 1
    check r.get.packages[0].source.get.objectLocator == bytesOf("plat-linux0")
    check s.statted == @["plat-darwin", "plat-linux0"]

  test "[PKG-0019] [PKG-0021] [PKG-0069] a catalog entry, Storage metadata and a locator that disagree with the manifest never override it":
    # The entry says lib@1.2.0, the locator names 1.2.0, the provider states the
    # archive's size; the archive is lib 1.0.0, and nothing else is believed.
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.2.0"), lib100)])
    let r = s.resolveIn(root("app"))
    check r.isErr
    check r.error.code == pecDependencyUnavailable
    check s.resolveIn(root("lib", "1.2.0")).isErr

  test "[PKG-0081] [PKG-0082] [PKG-0088] [PKG-0115] [PKG-0473] a candidate is judged by its own signature; nothing retrieved adds trust":
    # A catalog entry reaches an archive signed by an unaccepted key, and a
    # Storage object holds a trust file naming that key.
    let rogueTrust =
      trustOf([anchorOf("org", ["app", "lib"], testKey(2)[1])]).trustBytes
    var s = scene(
      [
        (entryOf("app", "1.0.0"), app100),
        (entryOf("lib", "1.3.0"), rogue130),
        (entryOf("lib", "1.2.0", locator = "trust.cbor"), rogueTrust),
      ]
    )
    let before = s.w.e.input.trust.len
    let r = s.resolveIn(root("app"))
    check r.isErr
    check r.error.code == pecDependencyUnavailable
    check s.w.e.input.trust.len == before
    check s.w.e.input.trust.anchor(bytesOf("org")).get.key == orgPub
    check s.w.e.cache.len == 1 # only app verified

  test "[PKG-0114] a detached signature beside an unsigned archive does not make it verify":
    let m = decodeManifest(encodeCbor(dataManifest("lib", "1.0.0"))).get
    let good = signManifest(m, bytesOf("org"), orgKey).get
    let other = decodeManifest(encodeCbor(dataManifest("lib", "0.9.0"))).get
    let wrong = signManifest(other, bytesOf("org"), orgKey).get
    # The archive's own manifest.cose signs another manifest; the right
    # signature sits beside it as a file.
    let archive = writeLgx(
      m.encoded,
      wrong,
      @[
        (
          "linux-x86_64",
          @[
            ("data/payload.bin", payloadOf("lib", "1.0.0")),
            ("data/manifest.cose", good),
          ],
        )
      ],
    ).get
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), archive)])
    let r = s.resolveIn(root("app"))
    check r.isErr
    check r.error.code == pecDependencyUnavailable
    let direct = s.w.e.cache.inspect(archive, s.w.e.input.trust)
    check direct.kind == ikIneligible

  test "[PKG-0166] [PKG-0167] a source with provenance_object resolves exactly as without, and no call names it":
    var plain =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    var e = entryOf("lib", "1.0.0")
    e.source.provenanceLocator = Opt.some(bytesOf("lib.provenance"))
    var withP = scene([(entryOf("app", "1.0.0"), app100), (e, lib100)])
    withP.objects[bytesOf("lib.provenance")] = bytesOf("a provenance object")
    let a = plain.resolveIn(root("app"))
    let b = withP.resolveIn(root("app"))
    check a.isOk
    check b.isOk
    check a.get.packages.mapIt(($it.identity, it.commitment)) ==
      b.get.packages.mapIt(($it.identity, it.commitment))
    check withP.calls.allIt(it.locator != bytesOf("lib.provenance"))
    check withP.statted == plain.statted
