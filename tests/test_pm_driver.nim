## The resolution driver and the engine's resolution (Tier 5 step 5-3b;
## DECISIONS G405; docs/PACKAGE-MANAGER.md §4). First the driver against one
## synchronous resolver run, over synthetic catalogs whose inspections come
## from a table (commitments are opaque to resolution); then the engine over
## real signed LGX archives served by a scripted provider.

import std/[os, sequtils, strutils, tables]
import unittest2
import logos_sdk/cbor
import logos_sdk/pins
import logos_sdk/base/hex
import ../src/logos_core/pins as core_pins
import ../src/logos_core/package/[errors, resolver]
import ../src/logos_core/daemon/config
import ../src/logos_core/pm/input_types as pm_input_types
import ./support/[pmfixture, pmshapes, pmworld]

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

proc scene(
    entries: openArray[(CatalogEntry, seq[byte])],
    trust = orgTrust,
    resolverLimits = MaxResolverLimits,
    turnWork = ResolverTurnWork,
    limits = Opt.none(pm_input_types.LcnPmLimits),
): Scene =
  ## The engine with `entries` as its kept, matching catalog and each archive
  ## (an empty one is absent) served under the entry's locator. `turnWork` is
  ## the work of one resolution turn (G455).
  var cat: seq[CatalogEntry]
  for (e, archive) in entries:
    cat.add(e)
    if archive.len > 0:
      result.objects[e.source.objectLocator] = archive
  let doc = catalogBytes(cat)
  result.objects[bytesOf("catalog")] = doc
  result.w = newWorld(
    doc,
    kept = keptFor(doc),
    limits = limits,
    trust = trust,
    resolverLimits = resolverLimits,
    turnWork = turnWork,
  )
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

  test "[ruling M5] [ruling S1] a resolver limit that ends an operation is named in the operator's log, with its value, and the caller's message shows no number":
    for (lim, name) in [
      (resolverLimits(1, 4095, 4096, 1_048_576).get, "partial_closure_names (1)"),
      (resolverLimits(4096, 4095, 4096, 1).get, "assignment_attempts (1)"),
    ]:
      checkpoint name
      var s = scene(
        [(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)],
        resolverLimits = lim,
      )
      let r = s.resolveIn(root("app"))
      let tripped = s.w.logs.filterIt("resolver limit" in it)
      check r.isErr and r.error.code == pecDependencyUnavailable
      check tripped == @["a root operation stopped at the resolver limit " & name]
      check not r.error.msg.anyIt(it in {'0' .. '9'})

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

# Turns (Tier 5 step 5-3c-2; DECISIONS G455) -----------------------------------------------

proc answerCall(s: var Scene) =
  ## Answers the oldest call the engine made, from the scene's objects.
  let c = s.w.take({cmStat, cmRead})
  s.calls.add(c)
  let data = s.objects.getOrDefault(c.locator, @[])
  let a =
    if c.locator notin s.objects:
      failureOf(fcUnavailable)
    elif c.kind == cmStat:
      sized(uint64(data.len))
    else:
      dataOf(data[int(c.offset) ..< int(c.offset) + int(c.length)])
  s.w.handle(answered(c.call, a))

proc untilTurn(s: var Scene, request: uint64) =
  ## Answers calls until `request` has a turn due.
  while request notin s.w.continues:
    doAssert s.w.has({cmStat, cmRead}), "no call to answer"
    s.answerCall()

proc replyTo(s: Scene, request: uint64): Result[Resolution, PackageError] =
  for c in s.w.replies:
    if c.request == request:
      return c.outcome
  doAssert false, "no reply to " & $request

suite "engine turns (G455)":
  # A turn budget of one work unit: every operation spans many turns, each a later event.
  # `lib` is listed at 40 more versions that `app`'s requirement rejects, never retrieved:
  # each is tested in a turn of its own.
  var entries = @[(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.2.0"), lib120)]
  for i in 0 ..< 40:
    entries.add((entryOf("lib", "2.0." & $i), newSeq[byte]()))

  test "[IMPL-DECISION G455] a spent turn continues in a later one; two operations take turns one after the other, with the outcomes of unsliced runs":
    var whole = scene(entries)
    let want = whole.resolveIn(root("app")).summary
    check want.startsWith("app@1.0.0")
    var s = scene(entries, turnWork = 1)
    s.w.emit(s.w.e.resolve(1, root("app")))
    s.w.emit(s.w.e.resolve(2, root("app")))
    var order: seq[uint64]
    while true:
      # An operation has one continue issued at a time.
      for op in [1'u64, 2]:
        check s.w.continues.countIt(it == op) <= 1
      if s.w.has({cmStat, cmRead}):
        s.answerCall()
      elif s.w.continues.len > 0:
        if s.w.continues[0] != ReleaseOperation:
          order.add(s.w.continues[0])
        discard s.w.turn()
      else:
        break
    check s.w.replies.len == 2
    check s.replyTo(1).summary == want
    check s.replyTo(2).summary == want
    var alternated = 0
    for i in 2 ..< order.len:
      if order[i] == order[i - 2] and order[i] != order[i - 1]:
        inc alternated
    checkpoint $order.len & " turns, " & $alternated & " alternations"
    check order.countIt(it == 1) > 40
    check order.countIt(it == 2) > 40
    check alternated > 40
    check s.w.e.releasingRuns == 0

  test "[IMPL-DECISION G455] [IMPL-DECISION G405] stop during a sliced operation answers it package-unavailable, and no turn follows (G437)":
    var s = scene(entries, turnWork = 1)
    s.w.emit(s.w.e.resolve(1, root("app")))
    s.untilTurn(1)
    check s.w.turn()
    check 1'u64 in s.w.continues
    check s.w.replies.len == 0
    s.w.emit(s.w.e.stop())
    check s.w.replies.len == 1
    check s.replyTo(1).isErr
    check s.replyTo(1).error.code == pecPackageUnavailable
    check s.w.e.pendingRequests == 0
    check s.w.e.releasingRuns == 0
    let issued = s.w.queue.len
    while s.w.turn():
      discard
    check s.w.replies.len == 1
    check s.w.queue.len == issued
    check s.w.e.resolve(2, root("app")).len == 0
    check s.w.e.stop().len == 0

  test "[IMPL-DECISION G455] a cancelled operation takes no more turns and is not answered; its queued retrieval is dropped, a late continue is ignored, and its run is released (F3)":
    var s = scene(entries, turnWork = 1)
    s.w.emit(s.w.e.resolve(1, root("app")))
    s.w.emit(s.w.e.resolve(2, root("lib", "1.2.0")))
    # Each run's setup takes turns before its first retrieval.
    while s.w.e.queued("main") < 2:
      doAssert s.w.turn(), "a turn is due"
    # The second retrieval waits behind the first: cancelled, it is dropped.
    s.w.emit(s.w.e.cancel(2))
    check s.w.e.queued("main") == 1
    s.untilTurn(1)
    s.w.emit(s.w.e.cancel(1))
    check 1'u64 in s.w.continues
    check s.w.e.pendingRequests == 0
    check s.w.e.releasingRuns == 2
    check s.w.e.cancel(1).len == 0
    let made = s.calls.len
    s.w.serve(s.objects, s.calls)
    check s.w.replies.len == 0
    check s.calls.len == made # `lib` is never retrieved
    check s.w.e.releasingRuns == 0
    check s.w.continues.len == 0

  test "[IMPL-DECISION G455] a finished operation's run is released turn by turn after its answer; no request takes the releases' id":
    var s = scene(entries, turnWork = 1)
    s.w.emit(s.w.e.resolve(1, root("app")))
    var releases = 0
    while s.w.has({cmStat, cmRead}) or s.w.continues.len > 0:
      if s.w.has({cmStat, cmRead}):
        s.answerCall()
        continue
      if s.w.continues[0] == ReleaseOperation:
        check s.w.replies.len == 1 # answered before any of its release
        check s.w.e.releasingRuns == 1
        inc releases
      discard s.w.turn()
    check s.replyTo(1).isOk
    check releases > 1
    check s.w.e.releasingRuns == 0
    s.w.emit(s.w.e.resolve(ReleaseOperation, root("app")))
    check s.w.replies.len == 2
    check s.replyTo(ReleaseOperation).error.code == pecInvalidRequest
    check s.w.continues.len == 0

# The measurement's shapes, by their counts -----------------------------------------

type Counted = object
  limit: string ## the limit that ends it; empty: none
  ok: bool
  names, depth, candidates, attempts, steps: int

proc counted(s: Shape, limits: ResolverLimits): Counted =
  let r = driveShape(s, limits)
  Counted(
    limit: r.counters.limit,
    ok: r.outcome.isOk,
    names: r.counters.names,
    depth: r.counters.depth,
    candidates: r.counters.mostConsidered,
    attempts: r.counters.attempts,
    steps: r.steps,
  )

func expect(
    limit = "", ok = false, names, depth, candidates, attempts, steps: int
): Counted =
  Counted(
    limit: limit,
    ok: ok,
    names: names,
    depth: depth,
    candidates: candidates,
    attempts: attempts,
    steps: steps,
  )

suite "the resolver measurement's shapes, by their counts (ruling M6; G443)":
  # [ruling M6] CI asserts the counts, which are deterministic, and never a time; the times
  # are `tools/pmbench.nim`'s, recorded in CONFORMANCE.md "Resolver limits". Each shape is the
  # bench's (`support/pmshapes.nim`) at a size CI runs in milliseconds; the counts follow from
  # the shape, as each comment says. A step is one resolver run: the root's, then one after
  # each inspection.
  let preset = resolverLimits(
    PresetPartialClosureNames.int, PresetDependencyDepth.int,
    PresetCandidatesPerName.int, PresetAssignmentAttempts.int,
  ).get
  let depthLimit = PresetDependencyDepth.int

  proc limitsWith(
      names = PresetPartialClosureNames.int,
      depth = PresetDependencyDepth.int,
      candidates = PresetCandidatesPerName.int,
      attempts = PresetAssignmentAttempts.int,
  ): ResolverLimits =
    resolverLimits(names, depth, candidates, attempts).get

  test "[IMPL-DECISION G443] a chain resolves to the preset's depth and no further":
    # n names, one candidate each: n attempts, the last name at depth n - 1, n inspections.
    let n = depthLimit + 1
    check chain(n).counted(preset) ==
      expect(
        ok = true, names = n, depth = n - 1, candidates = 1, attempts = n, steps = n + 1
      )
    # One more name lies beyond the depth limit: it is never bound.
    check chain(n + 1).counted(preset) ==
      expect(
        limit = "dependency_depth",
        names = n,
        depth = n - 1,
        candidates = 1,
        attempts = n,
        steps = n + 1,
      )

  test "[IMPL-DECISION G443] a dense closure and a layered one, at the preset's depth":
    # Each name of `dense` needs every later one, so the last is at depth n - 1, as in a chain.
    let n = depthLimit + 1
    check dense(n).counted(preset) ==
      expect(
        ok = true, names = n, depth = n - 1, candidates = 1, attempts = n, steps = n + 1
      )
    check dense(n + 1).counted(preset) ==
      expect(
        limit = "dependency_depth",
        names = n,
        depth = n - 1,
        candidates = 1,
        attempts = n,
        steps = n + 1,
      )
    # `layered` with as many layers as the depth limit: the first layer holds the root and one
    # more name, so its depth is the limit's; with one layer more, the last layer is beyond it.
    check layered(n, depthLimit).counted(preset) ==
      expect(
        ok = true,
        names = n,
        depth = depthLimit,
        candidates = 1,
        attempts = n,
        steps = n + 1,
      )
    check layered(n + 1, depthLimit + 1).counted(preset) ==
      expect(
        limit = "dependency_depth",
        names = n,
        depth = depthLimit,
        candidates = 1,
        attempts = n,
        steps = n + 1,
      )

  test "[G399] a chain longer than `partial_closure_names` ends at that limit":
    # The 9th name would make the partial closure 9 names: 8 bound, 9 inspected.
    check chain(10).counted(limitsWith(names = 8)) ==
      expect(
        limit = "partial_closure_names",
        names = 8,
        depth = 7,
        candidates = 1,
        attempts = 8,
        steps = 10,
      )

  test "[ruling M1] the wide shape tries every assignment of its k two-version names, and `assignment_attempts` ends it":
    # The root, then each of the 2^k assignments of the `a` names one name at a time:
    # 1 + 2 + ... + 2^k = 2^(k + 1) - 1 attempts; `b` is never bound, nor any of the `w` names
    # that sort after it. Inspected: the root and both versions of each `a` name.
    for k in [4, 6]:
      check wide(50, k).counted(limitsWith(attempts = MaxResolverLimits.attempts)) ==
        expect(
          names = k + 1,
          depth = 1,
          candidates = 2,
          attempts = (1 shl (k + 1)) - 1,
          steps = 2 * k + 2,
        )
    check wide(50, 6).counted(limitsWith(attempts = 20)) ==
      expect(
        limit = "assignment_attempts",
        names = 7,
        depth = 1,
        candidates = 2,
        attempts = 20,
        steps = 12,
      )

  test "[ruling 7.2] the hub binds each version of `y` over the whole core, and `candidates_per_name` ends it":
    # The root, the n core names and `y`: n + 2 names; `y` needs `c0000`, so the last core name
    # is at depth n + 1. Each of the v versions of `y` is one attempt and one inspection.
    const n = 30
    check hub(n, 1).counted(preset) ==
      expect(
        ok = true,
        names = n + 2,
        depth = n + 1,
        candidates = 1,
        attempts = n + 2,
        steps = n + 3,
      )
    check hub(n, 4).counted(preset) ==
      expect(
        names = n + 2,
        depth = n + 1,
        candidates = 4,
        attempts = n + 1 + 4,
        steps = n + 2 + 4,
      )
    # With 6 versions of `y` and room for 4, the fifth candidate is the limit's.
    check hub(4, 6).counted(limitsWith(candidates = 4)) ==
      expect(
        limit = "candidates_per_name",
        names = 6,
        depth = 5,
        candidates = 4,
        attempts = 9,
        steps = 10,
      )

  test "[IMPL-DECISION G454] the lift deepens the whole core with each newer `y` and gives it up; a deepening past the limit ends it":
    # The root, the n core names and `y`: n + 2 names. Each of the v - 1 newer versions of `y`
    # requires `c0000` one level deeper than the root does, so the last core name is at depth
    # n + 1, and `yz ^2.0.0`, which no version meets (never charged or inspected). `y@1.0.0`
    # completes the closure. Attempts: the root, the core and every version of `y`.
    const n = 30
    check lift(n, 1).counted(preset) ==
      expect(
        ok = true,
        names = n + 2,
        depth = n,
        candidates = 1,
        attempts = n + 2,
        steps = n + 3,
      )
    check lift(n, 4).counted(preset) ==
      expect(
        ok = true,
        names = n + 2,
        depth = n + 1,
        candidates = 4,
        attempts = n + 1 + 4,
        steps = n + 2 + 4,
      )
    # A core reaching the depth limit: the first newer `y` deepens its last name past it, which
    # ends the operation, though `y@1.0.0` would complete the closure (PM l.1276-1277). The
    # deepened depth is counted.
    check lift(depthLimit, 2).counted(preset) ==
      expect(
        limit = "dependency_depth",
        names = depthLimit + 2,
        depth = depthLimit + 1,
        candidates = 1,
        attempts = depthLimit + 2,
        steps = depthLimit + 3,
      )

  test "[IMPL-DECISION G455] each shape gives one outcome, the same counters and work, and the same retrievals under every turn budget; a small one slices it into turns":
    for (name, s, lim) in [
      ("chain", chain(depthLimit + 1), preset),
      ("dense", dense(depthLimit + 1), preset),
      ("layered", layered(depthLimit + 1, depthLimit), preset),
      ("wide", wide(50, 4), limitsWith(attempts = MaxResolverLimits.attempts)),
      ("wide at its limit", wide(50, 6), limitsWith(attempts = 20)),
      ("hub", hub(30, 4), preset),
      ("hub at its limit", hub(4, 6), limitsWith(candidates = 4)),
      ("lift", lift(30, 4), preset),
      ("lift past the depth", lift(depthLimit, 2), preset),
    ]:
      let base = driveShape(s, lim, NoTurnBudget)
      check base.turns == 0
      var most = high(int)
      for budget in [ResolverTurnWork, 1_000, 64, 17, 1]:
        checkpoint name & " under " & $budget
        let r = driveShape(s, lim, budget)
        check r.outcome.summary == base.outcome.summary
        check r.counters == base.counters
        check r.work == base.work
        check r.steps == base.steps + r.turns
        # A smaller budget never takes fewer turns.
        check r.turns >= (if most == high(int): 0 else: most)
        most = r.turns
        if budget == 1:
          check r.turns > 0
      # A budget of one unit ends a turn at each count: one unit, or a step counted as
      # several (a list's growth, a setup entry's bytes; chain: 522 turns for 1,231 units).
      check most >= int(base.work div 4)

  test "[IMPL-DECISION G455] (5-3c-3) contracts within the turn bound: each contract shape gives one outcome, the same counters, work and retrievals under every budget; every contract is counted with its bytes, and no step walks them in one go":
    # Each contract is numbered when its record is read: a unit and its 221 encoded bytes at
    # least. So the work exceeds them all, where before it counted none (5.2 s in one turn for
    # 18,000 contracts in one entry, G455's exception). And the most work between two turn
    # checks is a constant: one contract and the slots' growth, never a walk of an entry's or a
    # record's contracts.
    const LargestStep = 2_048
    for (name, s, contracts, outcome) in [
      ("contracts", contracts(2_000, 2), 2 * 2 * 2_000, "error dependency-unavailable"),
      ("provider", provider(5_000, 300), 1 + 5_000 + 300, "q@1.0.0"),
      ("versioned", versioned(1_000, 4), 4 * 1_000, "error dependency-unavailable"),
    ]:
      checkpoint name
      let base = driveShape(s, preset, NoTurnBudget)
      check base.outcome.summary.startsWith(outcome)
      check base.work > contracts * 222
      check base.largestStep <= LargestStep
      for budget in [ResolverTurnWork, 1_000, 64, 1]:
        checkpoint name & " under " & $budget
        let r = driveShape(s, preset, budget)
        check r.outcome.summary == base.outcome.summary
        check r.counters == base.counters
        check r.work == base.work
        check r.steps == base.steps + r.turns
        check r.largestStep <= LargestStep
        # Each resume spends less than its budget and one step more.
        check r.steps >= int(base.work div (budget + LargestStep))

  test "[IMPL-DECISION G455] (5-3c-3) contracts whose hashes collide (a test hook): each probe of the chain is a unit and a turn check, so the chain costs work and turns, never a step; the outcome, counters and work are the same under every budget":
    # The hash is unkeyed (the work must be the same in every run), so a signer can choose
    # encodings that collide (Fable's review of 5-3c-3 §1). The hook shifts each hash left by
    # 40 bits: every encoding starts at the same slot, and the k-th new one walks past the k
    # before it.
    const LargestStep = 2_048
    # contracts(1_100, 1): two entries of 1,100, a chain longer than LargestStep.
    let n = 2 * 1_100
    let spread = driveShape(contracts(1_100, 1), preset)
    contractHashShiftForTests = 40
    try:
      let chained = driveShape(contracts(1_100, 1), preset)
      check chained.outcome.summary == spread.outcome.summary
      check chained.counters == spread.counters
      check chained.work - spread.work >= int64(n * (n - 1) div 4)
      check chained.largestStep <= LargestStep
      let s = contracts(150, 1)
      let base = driveShape(s, preset, NoTurnBudget)
      check base.outcome.summary.startsWith("error dependency-unavailable")
      for budget in [ResolverTurnWork, 1_000, 64, 1]:
        checkpoint "under " & $budget
        let r = driveShape(s, preset, budget)
        check r.outcome.summary == base.outcome.summary
        check r.counters == base.counters
        check r.work == base.work
        check r.steps == base.steps + r.turns
        check r.largestStep <= LargestStep
    finally:
      contractHashShiftForTests = 0

  test "[IMPL-DECISION G477] the operation bound: a shape reads its records and their entries; at that count it resolves as without a bound, one below it ends package-unavailable, the same under every turn budget, with no limit named":
    # dense(n): n records and n(n-1)/2 dependency entries; chain(n): n records, n - 1 entries.
    check driveShape(dense(10), preset).counters.entries == 10 + 45
    check driveShape(chain(10), preset).counters.entries == 10 + 9
    for (name, s, lim) in [
      ("chain past the depth", chain(depthLimit + 1), preset),
      ("dense", dense(depthLimit + 1), preset),
      ("layered", layered(depthLimit + 1, depthLimit), preset),
      ("wide", wide(50, 4), limitsWith(attempts = MaxResolverLimits.attempts)),
      ("hub", hub(30, 4), preset),
      ("lift", lift(30, 4), preset),
    ]:
      let base = driveShape(s, lim, NoTurnBudget)
      let e = base.counters.entries
      check base.counters.bound == ""
      var first: BenchRun
      for budget in [NoTurnBudget, 64, 1]:
        checkpoint name & " under " & $budget
        let at = driveShape(s, lim, budget, Opt.some(e))
        check at.outcome.summary == base.outcome.summary
        check at.counters == base.counters
        let below = driveShape(s, lim, budget, Opt.some(e - 1))
        check below.outcome.summary == "error package-unavailable"
        check below.counters.bound == "operation_entries"
        check below.counters.limit == ""
        check below.counters.entries == e
        if budget == NoTurnBudget:
          first = below
        else:
          check below.counters == first.counters
          check below.work == first.work

# The worker and the spool (Tier 5 step 5-5-3; DECISIONS G446, G447) --------------------

type
  HoldsRef = object
    n: int
    r: ref int

  HoldsClosure = object
    f: proc()

  HoldsPointer = object
    p: pointer

proc junk(n: int): seq[byte] =
  ## `n` bytes that are no LGX archive: judged ineligible, which is all a spool test needs.
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(i mod 251)

proc spoolFiles(s: Scene): int =
  for _ in walkDir(s.w.spoolDir):
    inc result

proc reads(s: Scene): int =
  s.calls.countIt(it.kind == cmRead)

proc contractBytes(i: int): string =
  textOf(encodeCbor(cbor("contract-" & $i)))

proc judgedWire(s: Scene, archive: seq[byte]): WireOpened =
  ## The worker's encoded judgment of `archive`, as `wjOpen` answers it.
  var w: WorkerState
  discard
    w.runJob(WorkerJob(kind: wjStart, config: s.w.e.workerConfig(s.w.spoolDir)), nil)
  discard w.runJob(
    WorkerJob(
      kind: wjAppend,
      file: 900,
      first: true,
      name: spoolName(900, 900),
      chunk: textOf(archive),
    ),
    nil,
  )
  discard w.runJob(WorkerJob(kind: wjFinish, file: 900), nil)
  result = w.runJob(WorkerJob(kind: wjOpen, file: 900), nil).get.opened
  discard w.runJob(WorkerJob(kind: wjDrop, file: 900), nil)
  w.close()

proc padOpen(s: var Scene, job: WorkerJob, contracts: int) =
  ## Runs `wjOpen` and hands the engine its judgment with `contracts` more provided.
  s.w.work.delete(0)
  s.w.jobs.add(job.kind)
  var r = s.w.worker.runJob(job, nil).get
  doAssert r.opened.kind == ikEligible
  for i in 0 ..< contracts:
    r.opened.provides.add(contractBytes(i))
  s.w.handle(worked(r))

proc drive(s: var Scene) =
  ## Answers calls, runs worker jobs and turns until none is left.
  while true:
    if s.w.has({cmStat, cmRead}):
      s.answerCall()
    elif s.w.work.len > 0:
      discard s.w.runOne()
    elif s.w.continues.len > 0:
      discard s.w.turn()
    else:
      break

suite "the worker and the spool (G446, G447)":
  test "[IMPL-DECISION G447] what crosses to the worker holds no reference, checked at compile time":
    check refFree(WorkerJob)
    check refFree(WorkerResult)
    check refFree(WireOpened)
    check not refFree(Inspection) # its contracts are `CborValue`s
    check not refFree(CborValue)
    check not refFree(HoldsRef)
    check not refFree(HoldsClosure)
    check not refFree(HoldsPointer)
    check not refFree(seq[HoldsRef])
    check not refFree(cstring)
    check compiles(requireRefFree(WorkerJob))
    check not compiles(requireRefFree(Inspection))

  test "[IMPL-DECISION G447] a judgment crosses encoded and is decoded a budget at a time, unchanged":
    var w = WireOpened(kind: ikEligible, identity: ident("app@1.0.0"))
    w.dependencies.add(WireDependency(package: "lib", kind: rkExact, version: "1.0.0"))
    for i in 0 ..< 50:
      w.dependencies[0].contracts.add(contractBytes(i))
    for i in 0 ..< 3000:
      w.provides.add(contractBytes(1000 + i))
    check w.units == 3051 # the entry and its 50 contracts, and 3,000 provided
    var d = initDecoding(w)
    var budget = DecodeTurnUnits
    check not d.decodeSome(budget)
    check budget == 0
    budget = DecodeTurnUnits
    check not d.decodeSome(budget)
    budget = DecodeTurnUnits
    check d.decodeSome(budget)
    check budget == 3 * DecodeTurnUnits - 3051
    let o = d.take()
    check o.inspection.kind == ikEligible
    check o.inspection.identity == w.identity
    check o.inspection.dependencies.len == 1
    check o.inspection.dependencies[0].version == "1.0.0"
    check o.inspection.dependencies[0].contracts.mapIt(textOf(encodeCbor(it))) ==
      w.dependencies[0].contracts
    check o.inspection.provides.mapIt(textOf(encodeCbor(it))) == w.provides
    # A budget that runs out at every place, entries without contracts among them: each entry
    # once, and every contract in order.
    var many = WireOpened(kind: ikEligible, identity: ident("app@1.0.0"))
    for i in 0 ..< 7:
      var dep = WireDependency(package: "d" & $i, kind: rkCompatible, version: "1.0.0")
      for c in 0 ..< i mod 3:
        dep.contracts.add(contractBytes(10 * i + c))
      many.dependencies.add(dep)
    many.provides.add(contractBytes(99))
    for step in 1 .. 4:
      var e = initDecoding(many)
      var turns = 0
      while true:
        var b = step
        inc turns
        if e.decodeSome(b):
          break
      check turns >= many.units div step
      let got = e.take().inspection
      check got.dependencies.mapIt(it.package) == many.dependencies.mapIt(it.package)
      for i, dep in got.dependencies:
        check dep.contracts.mapIt(textOf(encodeCbor(it))) ==
          many.dependencies[i].contracts
      check got.provides.mapIt(textOf(encodeCbor(it))) == many.provides
    # [Fable's D1 condition 2] Bytes that do not decode are a fault in this process.
    var bad = initDecoding(WireOpened(kind: ikEligible, provides: @["\xff"]))
    budget = 1
    expect AssertionDefect:
      discard bad.decodeSome(budget)

  test "[IMPL-DECISION G447] a real judgment, every field set, crosses and comes back the same, and the cache's estimate by its encoded lengths is the walk's":
    var s = scene([(entryOf("app", "1.0.0"), app100)])
    var wire = s.judgedWire(app100)
    check wire.kind == ikEligible
    check wire.profile.len > 0
    check wire.kid.len > 0
    check wire.variant.len > 0
    check wire.dependencies.len > 0
    for i in 0 ..< 40:
      wire.dependencies[0].contracts.add(contractBytes(i))
    for i in 0 ..< 30:
      wire.provides.add(contractBytes(100 + i))
    var d = initDecoding(wire)
    var budget = 7
    while not d.decodeSome(budget):
      budget = 7
    let o = d.take()
    check o.inspection.estimatedBytes == wire.estimatedBytes
    check toWire(o) == wire
    for other in [
      WireOpened(
        kind: ikIneligible, error: packageError(pecInvalidPackage, "an archive's fault")
      ),
      WireOpened(kind: ikUnavailable, reason: "the archive could not be read"),
    ]:
      var d2 = initDecoding(other)
      var b2 = 1
      check d2.decodeSome(b2)
      let o2 = d2.take()
      check o2.inspection.estimatedBytes == other.estimatedBytes
      check toWire(o2) == other

  test "[PKG-0012] [PKG-0011] [PKG-0192] [IMPL-DECISION G447] an archive is spooled, never held: at most SpoolLag pieces wait for the worker; its file is the instance's own, never executable, and deleted once judged":
    let size = 5 * ReadStep + 100
    var s = scene([(entryOf("big", "1.0.0"), junk(size))])
    s.w.holdWork = true
    s.w.emit(s.w.e.resolve(1, root("big")))
    while s.w.has({cmStat, cmRead}):
      s.answerCall()
    check s.reads == SpoolLag # the next read waits for a piece to be written
    check s.w.work.len == SpoolLag
    check s.w.work.allIt(it.kind == wjAppend and it.chunk.len == ReadStep)
    check s.w.work[0].first and not s.w.work[1].first
    check s.w.e.spooled == 1
    check s.w.e.shareUsed == int64(size)
    check s.w.runOne() # one written: one more read
    check s.w.has({cmRead})
    # [PKG-0012] the archive's bytes go to a file below the instance's own root before anything
    # reads them; [PKG-0011] [PKG-0192] 0600 in a 0700 directory, never executable, read only by
    # the reader (the worker's jobs: append, finish, open, drop)
    var files: seq[string]
    for kind, path in walkDir(s.w.spoolDir):
      check kind == pcFile
      files.add(path)
    check files.len == 1
    check files[0].extractFilename.isSpoolName
    when defined(posix):
      check getFilePermissions(files[0]) == {fpUserRead, fpUserWrite}
      check getFilePermissions(s.w.spoolDir) == {fpUserRead, fpUserWrite, fpUserExec}
    s.answerCall()
    check s.reads == SpoolLag + 1
    check not s.w.has({cmRead})
    s.w.holdWork = false
    s.w.runWork()
    s.w.serve(s.objects, s.calls)
    check s.w.replies.len == 1
    check s.replyTo(1).isErr
    check s.reads == 6
    check s.w.jobs.countIt(it == wjOpen) == 1
    check s.w.jobs.countIt(it == wjDrop) == 1
    check s.w.e.spooled == 0
    check s.w.e.shareUsed == 0
    check s.spoolFiles == 0
    check s.w.e.cache.counters.opened == 1
    check s.w.jobs.allIt(it in {wjAppend, wjFinish, wjOpen, wjDrop})

  test "[IMPL-DECISION G446] the inspections' share: an archive that would pass 4 x archive_bytes waits, first in, first out, until a spool file is deleted":
    var entries: seq[(CatalogEntry, seq[byte])]
    for i in 0 ..< 5:
      entries.add((entryOf("p" & $i, "1.0.0"), junk(4000)))
    let limits = Opt.some(pm_input_types.LcnPmLimits(archive_bytes: Opt.some(4096'u64)))
    var s = scene(entries, limits = limits)
    s.w.holdWork = true
    for i in 0 ..< 5:
      s.w.emit(s.w.e.resolve(uint64(i + 1), root("p" & $i)))
    s.w.serve(s.objects, s.calls)
    check s.statted.len == 5
    check s.reads == 4
    check s.w.e.spooled == 4
    check s.w.e.shareUsed == 16000 # 4 x 4000 of 4 x 4096
    check s.w.e.shareWaiting == 1
    check s.w.replies.len == 0
    s.w.holdWork = false
    s.w.runWork()
    s.w.serve(s.objects, s.calls)
    check s.reads == 5
    check s.w.replies.len == 5
    check s.w.e.spooled == 0
    check s.w.e.shareUsed == 0
    check s.w.e.shareWaiting == 0
    check s.spoolFiles == 0

  test "[IMPL-DECISION G446] [IMPL-DECISION G455] a cancelled operation's archive is dropped: waiting for the share at once, spooled at its next step, never judged":
    var entries: seq[(CatalogEntry, seq[byte])]
    for i in 0 ..< 5:
      entries.add((entryOf("p" & $i, "1.0.0"), junk(4000)))
    let limits = Opt.some(pm_input_types.LcnPmLimits(archive_bytes: Opt.some(4096'u64)))
    var s = scene(entries, limits = limits)
    s.w.holdWork = true
    for i in 0 ..< 5:
      s.w.emit(s.w.e.resolve(uint64(i + 1), root("p" & $i)))
    s.w.serve(s.objects, s.calls)
    check s.w.e.shareWaiting == 1
    s.w.emit(s.w.e.cancel(5)) # waits for the share
    check s.w.e.queued("main") == 0
    s.w.emit(s.w.e.cancel(1)) # spooled, its digest not yet given
    check s.w.e.spooled == 4
    s.w.holdWork = false
    s.w.runWork()
    s.w.serve(s.objects, s.calls)
    check s.reads == 4
    check s.w.replies.mapIt(it.request) == @[2'u64, 3, 4]
    check s.w.jobs.countIt(it == wjOpen) == 3
    check s.w.e.spooled == 0
    check s.w.e.shareUsed == 0
    check s.spoolFiles == 0

  test "[PKG-0271] [IMPL-DECISION G446] a spool file that cannot be written ends the retrieval: the archive is unavailable and the log names the cause (PM l.1094)":
    var s = scene([(entryOf("big", "1.0.0"), junk(3 * ReadStep))])
    discard s.w.worker.runJob(
      WorkerJob(kind: wjStart, config: s.w.e.workerConfig(s.w.spoolDir / "missing")),
      nil,
    )
    let r = s.resolveIn(root("big"))
    check r.isErr
    check r.error.code == pecPackageUnavailable
    check s.reads < 3 # ended early; a read already issued is ignored
    check s.w.logs.anyIt(
      "could not be written to the spool on the state directory's file system" in it and
        "cannot create the spool file" in it
    )
    check s.w.jobs.countIt(it == wjOpen) == 0
    check s.w.e.spooled == 0
    check s.w.e.shareUsed == 0

  test "[IMPL-DECISION G447] a judgment of more than DecodeTurnUnits entries and contracts is decoded a turn at a time, between other events; the outcome is the same":
    let entries =
      @[(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.2.0"), lib120)]
    var whole = scene(entries)
    let want = whole.resolveIn(root("app")).summary
    check want.startsWith("app@1.0.0")
    var s = scene(entries)
    s.w.holdWork = true
    s.w.emit(s.w.e.resolve(1, root("app")))
    var padded = false
    var turns = 0
    while true:
      if s.w.has({cmStat, cmRead}):
        s.answerCall()
      elif s.w.work.len > 0:
        let job = s.w.work[0]
        if job.kind == wjOpen and not padded:
          # app's judgment, with 2500 more provided contracts
          s.w.work.delete(0)
          s.w.jobs.add(job.kind)
          var r = s.w.worker.runJob(job, nil).get
          check r.opened.kind == ikEligible
          for i in 0 ..< 2500:
            r.opened.provides.add(contractBytes(i))
          check r.opened.units > 2 * DecodeTurnUnits
          check r.opened.units <= 3 * DecodeTurnUnits
          padded = true
          s.w.handle(worked(r))
          check s.w.e.decoding == 1
          check DecodeOperation in s.w.continues
          check s.w.e.spooled == 0 # deleted once judged, before the decoding
        else:
          discard s.w.runOne()
      elif s.w.continues.len > 0:
        if s.w.continues[0] == DecodeOperation:
          inc turns
        discard s.w.turn()
      else:
        break
    check padded
    check turns == 3
    check s.w.replies.len == 1
    check s.replyTo(1).summary == want
    check s.w.e.decoding == 0
    s.w.emit(s.w.e.resolve(DecodeOperation, root("app")))
    check s.replyTo(DecodeOperation).error.code == pecInvalidRequest
    check s.spoolFiles == 0

  test "[IMPL-DECISION G447] a spool writer and a retrieval keep their running digest when copied (refc's copy through type information, upstream ISSUES 195)":
    let a = junk(3000)
    let b = junk(5000)
    var s = scene([(entryOf("app", "1.0.0"), app100)])
    var w = createSpool(s.w.spoolDir, spoolName(7, 1))
    var copied = w # as the worker's table copies its writers in and out
    copied.append(a)
    copied.append(b)
    check copied.finish() == blake3(a & b)
    check copied.failure.len == 0
    check removeSpool(copied.path).isOk
    var f = initRetrieval(bytesOf("x"), 1 shl 20, 1000)
    var g = f # as the engine's job queue copies its retrievals
    discard g.start()
    discard g.onAnswer(sized(uint64(a.len)))
    let step = g.onAnswer(dataOf(a))
    check step.kind == skDone
    check step.digest == blake3(a)

  test "[IMPL-DECISION G447] a second operation reaching an archive whose judgment is being decoded judges it itself: nothing sees a part (Fable's D1 condition 3)":
    let entries =
      @[(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.2.0"), lib120)]
    var whole = scene(entries)
    let want = whole.resolveIn(root("app")).summary
    var s = scene(entries)
    s.w.holdWork = true
    s.w.emit(s.w.e.resolve(1, root("app")))
    var padded, second, overlapped = false
    while true:
      if s.w.has({cmStat, cmRead}):
        s.answerCall()
      elif s.w.work.len > 0:
        let job = s.w.work[0]
        if job.kind == wjOpen and not padded:
          s.padOpen(job, 10 * DecodeTurnUnits) # ten turns
          padded = true
          check s.w.e.decoding == 1
          check s.w.e.cache.counters.opened == 0
          s.w.emit(s.w.e.resolve(2, root("app")))
          second = true
        else:
          if job.kind == wjOpen and padded and s.w.e.decoding >= 1:
            # The second operation's own judgment of app: its digest missed the cache,
            # which holds nothing of the first's yet.
            check s.w.e.cache.counters.opened == 0
            overlapped = true
          discard s.w.runOne()
      elif s.w.continues.len > 0:
        discard s.w.turn()
      else:
        break
    check second
    check overlapped
    check s.replyTo(1).summary == want
    check s.replyTo(2).summary == want
    check s.w.e.decoding == 0
    check s.spoolFiles == 0

  test "[IMPL-DECISION G447] [IMPL-DECISION G455] a judgment whose operation is cancelled while it is decoded, or before it arrives, is not finished: it is freed a turn at a time (Fable's D1 condition 5)":
    let entries = @[(entryOf("app", "1.0.0"), app100)]
    var s = scene(entries)
    s.w.holdWork = true
    s.w.emit(s.w.e.resolve(1, root("app")))
    var padded = false
    while not padded:
      if s.w.has({cmStat, cmRead}):
        s.answerCall()
      elif s.w.work.len > 0:
        let job = s.w.work[0]
        if job.kind == wjOpen:
          s.padOpen(job, 2500)
          padded = true
        else:
          discard s.w.runOne()
      else:
        discard s.w.turn()
    check s.w.e.decoding == 1
    while s.w.continues[0] != DecodeOperation:
      discard s.w.turn()
    discard s.w.turn() # one turn of decoding
    check s.w.e.decoding == 1
    s.w.emit(s.w.e.cancel(1))
    var turns = 0
    while s.w.continues.len > 0:
      if s.w.continues[0] == DecodeOperation:
        inc turns
        if turns == 1:
          discard s.w.turn()
          check s.w.e.decoding == 0
          check s.w.e.droppingDecodes == 1 # its 1,024 decoded and 2,500 encoded units
          continue
      discard s.w.turn()
    check turns >= 4
    check s.w.e.droppingDecodes == 0
    check s.w.e.cache.counters.opened == 0 # never admitted
    check s.w.replies.len == 0
    s.w.runWork() # the spool file's deletion, queued when the judgment arrived
    check s.spoolFiles == 0
    # Cancelled before its judgment arrives: the late answer is freed the same way.
    var late = scene(entries)
    late.w.holdWork = true
    late.w.emit(late.w.e.resolve(1, root("app")))
    while true:
      if late.w.has({cmStat, cmRead}):
        late.answerCall()
      elif late.w.work.len > 0:
        let job = late.w.work[0]
        if job.kind == wjOpen:
          late.w.emit(late.w.e.cancel(1))
          late.padOpen(job, 2500)
          break
        discard late.w.runOne()
      else:
        discard late.w.turn()
    check late.w.e.decoding == 0
    check late.w.e.droppingDecodes == 1
    var lateTurns = 0
    while late.w.continues.len > 0:
      if late.w.continues[0] == DecodeOperation:
        inc lateTurns
      discard late.w.turn()
    check lateTurns >= 3
    check late.w.e.droppingDecodes == 0
    check late.w.e.cache.counters.opened == 0
    check late.w.replies.len == 0
    late.w.runWork()
    check late.spoolFiles == 0
