## The verification cache (Tier 5 step 5-3b; DECISIONS G403; C5;
## docs/PACKAGE-MANAGER.md §5): a hit, each invalidation against a second
## trust input, rotation, and the bound. The trust input is fixed within one
## start (Q10), so the suite drives the cache with two inputs directly. Step
## 5-5-1 adds PKG-0060 (G451): a selected module's configuration declaration
## that does not resolve makes the archive `invalid-package`.

import std/[sequtils, strutils]
import unittest2
import logos_sdk/cbor
import ../src/logos_core/package/[errors, manifest, records, resolver, signing]
import ../src/logos_core/pm/vcache
import ./support/[lgxbuild, pmfixture, valueinspection]

let (orgKey, orgPub) = testKey(1)
let (newKey, newPub) = testKey(2)
let (devKey, devPub) = testKey(3)

# Built once: each signature takes about a second.
let example1 = packed(dataManifest("logos.example", "1.0.0"), "org", orgKey)
let wallet1 = packed(dataManifest("logos.wallet", "1.0.0"), "org", orgKey)
let other1 = packed(dataManifest("logos.other", "1.0.0"), "org", orgKey)
let example2 = packed(dataManifest("logos.example", "2.0.0"), "new", newKey)
let example3 = packed(dataManifest("logos.example", "3.0.0"), "dev", devKey)

let base =
  trustInputOf([("org", orgPub, @["logos.example", "logos.other", "logos.wallet"])])

proc cacheOf(capacity = 16): VerificationCache =
  initVerificationCache(capacity, linuxHost, pathRules = PathRules())

proc eligible(i: Inspection): bool =
  i.kind == ikEligible

proc signatureFailed(i: Inspection): bool =
  i.kind == ikIneligible and i.error.code == pecSignature

suite "verification cache (G403)":
  test "[PKG-0076] a hit answers without opening the archive":
    var c = cacheOf()
    let first = c.inspect(example1, base)
    check first.eligible
    check c.counters.opened == 1
    let again = c.inspect(example1, base)
    check again.eligible
    check c.counters.opened == 1
    check c.counters.hits == 1
    check again.identity == first.identity
    check again.commitment == first.commitment
    check c.len == 1
    check blake3(example1) in c

  test "an archive that does not verify is not cached":
    var c = cacheOf()
    let none = TrustInput()
    let a = c.inspect(example1, none)
    check a.signatureFailed
    check c.len == 0
    discard c.inspect(example1, none)
    check c.counters.opened == 2
    check c.counters.hits == 0

  test "[PKG-0077] [PKG-0080] a removed anchor: its entries are dropped and fail, the others stay":
    let two = trustInputOf(
      [
        ("org", orgPub, @["logos.example", "logos.wallet"]),
        ("new", newPub, @["logos.example"]),
      ]
    )
    var c = cacheOf()
    check c.inspect(example1, two).eligible
    check c.inspect(example2, two).eligible
    let removed = trustInputOf([("new", newPub, @["logos.example"])])
    let a = c.inspect(example1, removed)
    check a.signatureFailed
    check c.counters.dropped == 1
    check example1.blake3 notin c
    let b = c.inspect(example2, removed)
    check b.eligible
    check c.counters.hits == 1

  test "[PKG-0077] a withdrawn name drops only the entries for that name":
    var c = cacheOf()
    check c.inspect(example1, base).eligible
    check c.inspect(wallet1, base).eligible
    let narrowed = trustInputOf([("org", orgPub, @["logos.wallet"])])
    check c.inspect(wallet1, narrowed).eligible
    check c.counters.hits == 1
    check c.inspect(example1, narrowed).signatureFailed
    check c.counters.dropped == 1

  test "[PKG-0077] a new key for the same kid drops the old key's entries":
    var c = cacheOf()
    check c.inspect(example1, base).eligible
    let rekeyed = trustInputOf([("org", newPub, @["logos.example", "logos.wallet"])])
    check c.inspect(example1, rekeyed).signatureFailed
    check c.counters.dropped == 1
    check c.counters.hits == 0

  test "[PKG-0077] a withdrawn development anchor drops its entries":
    let anchors = @[
      LcnTrustAnchor(
        kid: bytesOf("dev"),
        public_key: @devPub,
        packages: @["logos.example"],
        development: true,
      ),
      anchorOf("org", ["logos.example", "logos.wallet"], orgPub),
    ]
    var on = trustOf(anchors)
    on.development = true
    var off = on
    off.development = false
    let withDev = acceptedSigning(on).get
    let withoutDev = acceptedSigning(off).get
    var c = cacheOf()
    check c.inspect(example3, withDev).eligible
    check c.inspect(example1, withDev).eligible
    check c.inspect(example3, withoutDev).signatureFailed
    check c.inspect(example1, withoutDev).eligible
    check c.counters.dropped == 1
    check c.counters.hits == 1

  test "[PKG-0077] an entry under another profile is no longer accepted":
    var c = cacheOf()
    check c.inspect(example1, base).eligible
    let e = CacheEntry(
      profile: "logos.package-signing.other",
      kid: bytesOf("org"),
      key: orgPub,
      identity: PackageIdentity(package: "logos.example", version: "1.0.0"),
    )
    check not e.stillAccepted(base)
    var same = e
    same.profile = signingProfile()
    check same.stillAccepted(base)

  test "judge drops what a changed trust input no longer accepts, and nothing else":
    var c = cacheOf()
    check c.inspect(example1, base).eligible
    check c.inspect(wallet1, base).eligible
    check c.judge(base) == 0
    check c.judge(trustInputOf([("org", orgPub, @["logos.wallet"])])) == 1
    check c.len == 1
    check wallet1.blake3 in c

  test "[PKG-0079] rotation: during an overlap both anchors verify; after the old one is removed, only the new one":
    let overlap = trustInputOf(
      [("org", orgPub, @["logos.example"]), ("new", newPub, @["logos.example"])]
    )
    var c = cacheOf()
    check c.inspect(example1, overlap).eligible
    check c.inspect(example2, overlap).eligible
    let after = trustInputOf([("new", newPub, @["logos.example"])])
    check c.inspect(example2, after).eligible
    check c.inspect(example1, after).signatureFailed

  test "the bound: the least recently used entry goes first":
    var c = cacheOf(capacity = 2)
    check c.inspect(example1, base).eligible
    check c.inspect(wallet1, base).eligible
    check c.inspect(example1, base).eligible # used again: wallet1 is now the oldest
    check c.inspect(other1, base).eligible
    check c.len == 2
    check c.counters.evicted == 1
    check wallet1.blake3 notin c
    check example1.blake3 in c
    check other1.blake3 in c
    let opened = c.counters.opened
    check c.inspect(wallet1, base).eligible
    check c.counters.opened == opened + 1

suite "configuration declarations at inspection (PKG-0060, G451)":
  let zeros = Opt.some(newSeq[byte](32))
  let tunerRoot = Opt.some(rootsOf(tunerDocument, TunerRoot)[0])

  proc archiveWith(c: ConfigSpec): seq[byte] =
    packed(modulePackage(config = Opt.some(c)), "org", orgKey)

  proc invalidPackage(i: Inspection): bool =
    if i.kind == ikIneligible:
      checkpoint i.error.msg
    i.kind == ikIneligible and i.error.code == pecInvalidPackage

  test "[PKG-0060] invalid CDDL, a document commitment mismatch, an absent root, an unresolved reference and an invalid default are each invalid-package":
    let cases = [
      (
        ConfigSpec(schema: "tuner.config = {", root: TunerRoot, schemaRoot: zeros),
        "the configuration schema is not accepted",
      ),
      (
        tunerSpec().withRoot(zeros),
        "the configuration schema root is not the declared one",
      ),
      (
        ConfigSpec(
          schema: tunerDocument,
          root: "tuner.absent",
          schemaRoot: tunerRoot,
          default: Opt.some(tunerValue()),
        ),
        "the configuration root tuner.absent is not a type of its schema",
      ),
      (
        ConfigSpec(
          schema: "tuner.config = { station: radio.station }\n",
          root: TunerRoot,
          schemaRoot: zeros,
        ),
        "the configuration schema is not accepted",
      ),
      (
        tunerSpec(Opt.some(encodeCbor(cborMap()))),
        "the default value is not a complete value of tuner.config",
      ),
    ]
    for (c, why) in cases:
      checkpoint c.schema & " / " & c.root
      var cache = cacheOf()
      let i = cache.inspect(archiveWith(c), base)
      check i.invalidPackage
      if i.kind == ikIneligible:
        check i.error.msg.startsWith("module alpha_module: " & why)
      check cache.len == 0 # an ineligible archive is not cached

  test "a package with a valid configuration is eligible, and one without is unchanged":
    var c = cacheOf()
    let tuner = c.inspect(archiveWith(tunerSpec()), base)
    check tuner.eligible
    check c.inspect(archiveWith(tunerSpec(Opt.none(seq[byte]), live = true)), base).eligible
    let plain = packed(modulePackage(config = Opt.none(ConfigSpec)), "org", orgKey)
    check c.inspect(plain, base).eligible
    check c.inspect(example1, base).eligible
    check c.len == 4

# The byte bound (step 5-5-3, G447) ------------------------------------------------------

proc bigManifest(target: int): CborValue =
  ## A package whose inspection's estimate is exactly `target`: plain dependencies, their names
  ## padded so the walk's bytes add up.
  let record = RecordUnitBytes + "logos.big".len + "1.0.0".len
  let per = DependencyUnitBytes + "logos.d00000".len + "1.0.0".len
  let n = (target - record) div per
  var pad = target - record - n * per
  var names = newSeq[string](n)
  for i in 0 ..< n:
    names[i] = "logos.d" & align($i, 5, '0')
  var i = n - 1
  while pad > 0:
    let k = min(pad, 100)
    names[i].add('x'.repeat(k))
    pad -= k
    dec i
  var deps: seq[(string, string)]
  for name in names:
    deps.add((name, "1.0.0"))
  dataManifest("logos.big", "1.0.0", deps)

let
  atBound = packed(bigManifest(MaxCachedInspectionBytes), "org", orgKey)
  overBound = packed(bigManifest(MaxCachedInspectionBytes + 1), "org", orgKey)
  bigTrust = trustInputOf([("org", orgPub, @["logos.big"])])

proc contract(i: int): CborValue =
  ## A commitment decoded from its bytes, as the module thread holds one.
  var root = newSeq[byte](32)
  for k in 0 ..< 4:
    root[k] = byte((i shr (8 * k)) and 0xff)
  decodeCbor(encodeCbor(commitmentValue(root))).get

proc shapedValues(deps, perDep, provided, salt: int): ValueInspection =
  result = ValueInspection(
    kind: ikEligible,
    identity: PackageIdentity(package: "logos.shape", version: "1.0." & $salt),
  )
  result.commitment.commitmentModel = "logos.commitment-model.2026-10"
  result.commitment.hashProfile = "logos.hash-profile.2026-08.choice-index"
  result.commitment.hashSuite = "logos.hash-suite.blake3-256"
  for d in 0 ..< deps:
    var dep = PackageDependency(
      package: "logos.d" & align($d, 9, '0'), kind: rkCompatible, version: "1.0.0"
    )
    for c in 0 ..< perDep:
      dep.contracts.add(contract(salt * 7919 + d * 131 + c))
    result.dependencies.add(dep)
  for c in 0 ..< provided:
    result.provides.add(contract(salt * 104_729 + c))

proc shaped(deps, perDep, provided, salt: int): Inspection =
  ## [G482] The inspection the worker builds of those values.
  held(shapedValues(deps, perDep, provided, salt))

proc retained(deps, perDep, provided, copies: int): int =
  ## The heap's growth per inspection over `copies` built one by one.
  GC_fullCollect()
  var held = newSeq[Inspection](copies)
  let before = getOccupiedMem()
  for i in 0 ..< copies:
    held[i] = shaped(deps, perDep, provided, i + 1)
  GC_fullCollect()
  result = (getOccupiedMem() - before) div copies
  check held.len == copies

suite "verification cache: the byte bound (G447)":
  test "[G447] an inspection at 256 KiB by the estimate is cached; one byte over is answered and not":
    var c = cacheOf()
    let at = c.inspect(atBound, bigTrust)
    check at.eligible
    check at.estimatedBytes == MaxCachedInspectionBytes
    check c.len == 1
    check c.counters.uncached == 0
    let over = c.inspect(overBound, bigTrust)
    check over.eligible
    check over.estimatedBytes == MaxCachedInspectionBytes + 1
    check c.len == 1
    check c.counters.uncached == 1
    # The next reach opens the archive again; the cached one is a hit.
    check c.inspect(overBound, bigTrust).eligible
    check c.counters.opened == 3
    check c.counters.uncached == 2
    check c.inspect(atBound, bigTrust).eligible
    check c.counters.hits == 1
    check c.counters.opened == 3

  test "[G447] [G482] the estimate is fixed by rule: the same number in every build, the walk's":
    var v = shapedValues(2, 0, 1, 1)
    v.dependencies[0].contracts.add(contract(9))
    let x = held(v)
    # The record: 2,048 and its identity text; each entry 192 and its name and version; each
    # contract 192 and its 190 encoded bytes.
    check encodedSize(v.provides[0]) == 190
    check x.estimatedBytes ==
      2048 + "logos.shape1.0.1".len + 2 * (192 + "logos.d000000000".len + 5) +
      2 * (192 + 190)
    check x.estimatedBytes == 3254
    var walked = 0
    for u in x.inputUnits:
      walked += unitBytes(u.kind) + u.bytes
    check walked == x.estimatedBytes

  test "[G447] [G482] the estimate is at least what an inspection holds, for five shapes, the costliest per contract among them":
    when defined(asan) or defined(tsan) or defined(msan) or defined(useMalloc):
      skip() # the sanitizers' allocator is not Nim's: no occupied-memory figure
    else:
      for (name, deps, perDep, provided) in [
        ("plain dependencies", 1000, 0, 0),
        ("dependencies that list contracts", 100, 10, 0),
        ("many provided contracts", 0, 0, 1000),
        ("one provided contract", 0, 0, 1),
        ("22 provided contracts, the buffer rounded up to two pages (G482)", 0, 0, 22),
      ]:
        let held = retained(deps, perDep, provided, 40)
        let estimate = shaped(deps, perDep, provided, 1).estimatedBytes
        checkpoint name & ": holds " & $held & " B, estimated " & $estimate & " B"
        check estimate >= held

  test "[G447] a record's constant covers its cache entry and table slot":
    when defined(asan) or defined(tsan) or defined(msan) or defined(useMalloc):
      skip()
    else:
      var c = initVerificationCache(4096, linuxHost, pathRules = PathRules())
      GC_fullCollect()
      let before = getOccupiedMem()
      for i in 0 ..< 4096:
        var d: Blake3Digest
        for k in 0 ..< 4:
          d[k] = byte((i shr (8 * k)) and 0xff)
        let o = Opened(
          inspection: shaped(0, 0, 0, i + 1),
          profile: signingProfile(),
          kid: bytesOf("org"),
          variant: "linux-x86_64",
        )
        discard c.admit(d, o, o.inspection.estimatedBytes)
      GC_fullCollect()
      let each = (getOccupiedMem() - before) div 4096
      let estimate = shaped(0, 0, 0, 4096).estimatedBytes
      checkpoint "each entry holds " & $each & " B, estimated " & $estimate & " B"
      check c.len == 4096
      check estimate >= each

suite "verification cache: an archive's encodings (G482)":
  test "[G482] an archive's inspection holds its manifest's encodings: each dependency's contracts as listed, then the provided ones as `provided` gives them; it walks as the values do":
    var p = modulePackage(deps = [("logos.other", "1.0.0"), ("logos.wallet", "1.0.0")])
    let listed = @[@[commitmentValue(8), commitmentValue(9)], @[commitmentValue(5)]]
    for e in p.manifest.entries.mitems:
      if e.key.getText == Opt.some("dependencies"):
        for i, d in e.value.items.mpairs:
          d.entries.add((cbor("contracts"), cborArray(listed[i])))
    let m = p.decoded
    check m.dependencies.mapIt(it.contracts.len) == @[2, 1]
    let provides = provided(m.modules)
    check provides.len == 5 # alpha's primary, two implemented, two extended
    var c = cacheOf()
    let x = c.inspect(packed(p, "org", orgKey), base)
    check x.eligible
    check x.identity == m.identity
    let v = ValueInspection(
      kind: ikEligible,
      identity: x.identity,
      commitment: x.commitment,
      dependencies: m.dependencies,
      provides: provides,
    )
    check x.matches(v)
    check x.contractCount == 8
    check x.providedCount == 5
    var units: seq[InputUnit]
    for u in x.inputUnits:
      units.add(u)
    check units == valueUnits(v)
