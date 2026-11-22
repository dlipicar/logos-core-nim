## The verification cache (Tier 5 step 5-3b; DECISIONS G403; C5;
## docs/PACKAGE-MANAGER.md §5): a hit, each invalidation against a second
## trust input, rotation, and the bound. The trust input is fixed within one
## start (Q10), so the suite drives the cache with two inputs directly. Step
## 5-5-1 adds PKG-0060 (G451): a selected module's configuration declaration
## that does not resolve makes the archive `invalid-package`.

import std/strutils
import unittest2
import ../src/logos_core/package/[errors, resolver]
import ../src/logos_core/pm/vcache
import ./support/[lgxbuild, pmfixture]

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
