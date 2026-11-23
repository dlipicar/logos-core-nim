## The resolver measurement's catalog shapes (Tier 5 step 5-3b-2; planning's rulings of
## 2026-11-22, M1 to M6 and 7.1 to 7.2; DECISIONS G399, G443), resolved through the Package
## Manager's driver (`pm/driver.nim`) one step at a time, as the engine runs it on the module
## thread: since 5-3c-2 (G455) a step resumes the run until it needs an inspection, spends its
## turn or ends, and the run is then released a turn at a time. Every inspection is answered from a table, so no archive is
## signed or read. `tools/pmbench.nim` times them; `test_pm_driver` asserts their counts at small
## sizes, never a time (M6).
##
## - `wide`: a root with `w` dependency names that sort last and `k` names that sort first, each
##   with two versions, then a name no candidate satisfies, so every assignment of the `k` names
##   is tried (M1).
## - `dense`: `n` names, each depending on every later one (M3).
## - `layered`: `n` names in `L` layers, each depending on every name of a later layer, the root
##   also on the rest of its own: as dense, at depth `L` (32 is the preset's, G443).
## - `chain`: `n` names, each depending on the next (M3).
## - `hub`: a dense core of `n` names, then `y`, sorting last, which requires every one of them, so
##   each bind of `y` checks every bound dependency for a cycle (`bindCand`; the ruling of
##   2026-11-22, 7.2). With `v` versions of `y` and a name after it that no candidate satisfies,
##   `y` is bound `v` times.
## - `lift`: a dense core of `n` names, then `y`, sorting after it, whose `v` - 1 newer versions
##   each require the core's first name one level deeper than the root does, and `yz ^2.0.0`, of
##   which only 1.0.0 exists: each deepens every core name and is given up, and `y@1.0.0`, which
##   requires nothing, completes the closure at the core's first depths. Propagation's worst case
##   (5-3c's plan §6; G454).

import std/[monotimes, strutils, tables, times]
import results
import logos_sdk/pins
import logos_sdk/base/hex
import ../../src/logos_core/pins as core_pins
import ../../src/logos_core/package/[errors, manifest, records, resolver, trust]
import ../../src/logos_core/pm/driver

export results, errors, resolver

proc digestOf(h: string): typeof(ManifestCommitment().schemaRoot) =
  let bytes = hex.fromHex(h).get
  for i in 0 ..< result.len:
    result[i] = bytes[i]

proc b(s: string): seq[byte] =
  @(s.toOpenArrayByte(0, s.high))

let commitment = ManifestCommitment(
  commitmentModel: CommitmentModelId,
  schemaRoot: digestOf(core_pins.PackageManifestSchemaRoot),
  schemaSubtreeRoot: digestOf(core_pins.PackageManifestSubtreeRoot),
)

type Shape* = object
  catalog: seq[CatalogEntry]
  answers: Table[seq[byte], Inspection]
  root: string
  rootVersion: string

proc add(s: var Shape, name, version: string, deps: seq[PackageDependency]) =
  let src =
    PackageSource(kind: skLgx, storage: "main", objectLocator: b(name & "@" & version))
  s.catalog.add(
    CatalogEntry(
      identity: PackageIdentity(package: name, version: version), source: src
    )
  )
  s.answers[src.encoded] = Inspection(
    kind: ikEligible,
    identity: PackageIdentity(package: name, version: version),
    commitment: commitment,
    dependencies: deps,
  )

func needs(name: string, version = "1.0.0"): PackageDependency =
  PackageDependency(package: name, kind: rkCompatible, version: version)

proc wide*(w, k: int): Shape =
  ## [M1] `r` needs `a00`..`a<k-1>` (two versions each), `b ^2.0.0` (only 1.0.0 exists) and
  ## `z000000`..: the search binds the `a` names in every combination and fails at `b` each time.
  var deps: seq[PackageDependency]
  for i in 0 ..< k:
    let a = "a" & align($i, 2, '0')
    deps.add(needs(a))
    result.add(a, "1.1.0", @[])
    result.add(a, "1.0.0", @[])
  deps.add(needs("b", "2.0.0"))
  result.add("b", "1.0.0", @[])
  for i in 0 ..< w:
    deps.add(needs("z" & align($i, 6, '0')))
  result.add("r", "1.0.0", deps)
  result.root = "r"
  result.rootVersion = "1.0.0"

proc dense*(n: int): Shape =
  ## [M3] `d0000` needs every later name, and so on: n(n-1)/2 edges.
  proc d(i: int): string =
    "d" & align($i, 4, '0')

  for i in 0 ..< n:
    var deps: seq[PackageDependency]
    for j in i + 1 ..< n:
      deps.add(needs(d(j)))
    result.add(d(i), "1.0.0", deps)
  result.root = d(0)
  result.rootVersion = "1.0.0"

proc layered*(n, layers: int): Shape =
  ## [G443] `n` names in `layers` layers of about equal size; each needs every name of every
  ## later layer, and the root the rest of its own, so the depth is `layers`.
  proc d(i: int): string =
    "d" & align($i, 4, '0')

  proc layer(i: int): int =
    i * layers div n

  for i in 0 ..< n:
    var deps: seq[PackageDependency]
    for j in i + 1 ..< n:
      if layer(j) > layer(i):
        deps.add(needs(d(j)))
    result.add(d(i), "1.0.0", deps)
  # The root is the first name; it needs the rest of its own layer too.
  for j in 1 ..< n:
    if layer(j) == 0:
      result.answers[result.catalog[0].source.encoded].dependencies.add(needs(d(j)))
  result.root = d(0)
  result.rootVersion = "1.0.0"

proc chain*(n: int): Shape =
  ## [M3] `p0000` needs `p0001`, which needs `p0002`, ...
  proc p(i: int): string =
    "p" & align($i, 4, '0')

  for i in 0 ..< n:
    result.add(p(i), "1.0.0", (if i + 1 < n: @[needs(p(i + 1))] else: @[]))
  result.root = p(0)
  result.rootVersion = "1.0.0"

proc hub*(n, v: int): Shape =
  ## [ruling 7.2] `r` needs `c0000` (the core: each name needs every later one) and `y`, whose
  ## `v` versions each need the whole core; with `v` > 1 `r` also needs `yz ^2.0.0`, of which
  ## only 1.0.0 exists, so every version of `y` is bound and then given up.
  proc c(i: int): string =
    "c" & align($i, 4, '0')

  for i in 0 ..< n:
    var deps: seq[PackageDependency]
    for j in i + 1 ..< n:
      deps.add(needs(c(j)))
    result.add(c(i), "1.0.0", deps)
  var core: seq[PackageDependency]
  for i in 0 ..< n:
    core.add(needs(c(i)))
  for i in countdown(v - 1, 0):
    result.add("y", "1." & $i & ".0", core)
  var rootDeps = @[needs(c(0)), needs("y")]
  if v > 1:
    rootDeps.add(needs("yz", "2.0.0"))
    result.add("yz", "1.0.0", @[])
  result.add("r", "1.0.0", rootDeps)
  result.root = "r"
  result.rootVersion = "1.0.0"

func rootOf*(s: Shape): RootReference =
  RootReference(package: Opt.some(s.root), version: Opt.some(s.rootVersion))

proc inputOf*(s: Shape, limits: ResolverLimits): ResolverInput =
  ## [IMPL-DECISION G454] The shape as one synchronous resolver run's input, every inspection
  ## answered from the table and nothing installed: what `test_resolver` compares with the frozen
  ## oracle and what `tools/pmbench.nim --sync` times.
  let answers = s.answers
  ResolverInput(
    catalog: s.catalog,
    limits: limits,
    inspect: proc(
        source: PackageSource, trust: TrustInput
    ): Inspection {.gcsafe, raises: [].} =
      answers.getOrDefault(
        source.encoded, Inspection(kind: ikUnavailable, reason: "no such source")
      ),
    retained: proc(p: InstalledPackage): Result[void, string] {.gcsafe, raises: [].} =
      ok(),
  )

proc lift*(n, v: int): Shape =
  ## [G454] See the module's header.
  proc c(i: int): string =
    "c" & align($i, 4, '0')

  for i in 0 ..< n:
    var deps: seq[PackageDependency]
    for j in i + 1 ..< n:
      deps.add(needs(c(j)))
    result.add(c(i), "1.0.0", deps)
  for i in countdown(v - 1, 1):
    result.add("y", "1." & $i & ".0", @[needs(c(0)), needs("yz", "2.0.0")])
  result.add("y", "1.0.0", @[])
  result.add("yz", "1.0.0", @[])
  result.add("r", "1.0.0", @[needs(c(0)), needs("y")])
  result.root = "r"
  result.rootVersion = "1.0.0"

type BenchRun* = object
  outcome*: Result[Resolution, PackageError]
  counters*: ResolverCounters
  steps*: int
    ## driver steps: one ending at each inspection, one at each spent turn
    ## ([G455]) and the last
  turns*: int ## the steps that ended with the turn spent
  work*: int64 ## the work units the run counted
  longest*, total*: Duration ## wall time
  longestCpu*, totalCpu*: float ## the process's CPU time, in seconds
  setup*: Duration ## [G455] making the run (`initDriver`), before its first turn
  setupCpu*: float
  releases*: int ## [G455] the turns that released the run after its outcome
  longestRelease*, releaseTotal*: Duration ## their wall time
  longestReleaseCpu*, releaseTotalCpu*: float

func defaultParameter*(shape: string): int =
  ## `k` for `wide`, `v` for `hub` and `lift`, `L` for `layered`.
  case shape
  of "hub": 1
  of "lift": 2
  of "layered": 32
  else: 20

proc shapeOf*(name: string, size, parameter: int): Opt[Shape] =
  case name
  of "wide":
    Opt.some(wide(size, parameter))
  of "dense":
    Opt.some(dense(size))
  of "chain":
    Opt.some(chain(size))
  of "hub":
    Opt.some(hub(size, parameter))
  of "layered":
    Opt.some(layered(size, parameter))
  of "lift":
    Opt.some(lift(size, parameter))
  else:
    Opt.none(Shape)

proc driveShape*(
    s: Shape,
    limits: ResolverLimits,
    budget = ResolverTurnWork,
    operationEntries = Opt.none(int),
): BenchRun =
  ## Runs the driver to its outcome, answering every inspection from the table at once.
  ## `budget` is the work of one turn ([G455]); `operationEntries` the operation bound
  ## ([G477]).
  var t: TrustInput
  let made = getMonoTime()
  let made0 = cpuTime()
  let d = initDriver(s.catalog, t, limits, s.rootOf, budget, operationEntries)
  result.setupCpu = cpuTime() - made0
  result.setup = getMonoTime() - made
  while true:
    let start = getMonoTime()
    let cpu0 = cpuTime()
    let st = d.step()
    let cpu = cpuTime() - cpu0
    let took = getMonoTime() - start
    inc result.steps
    result.total += took
    result.totalCpu += cpu
    if took > result.longest:
      result.longest = took
    if cpu > result.longestCpu:
      result.longestCpu = cpu
    case st.kind
    of dsNeed:
      d.supply(
        st.source,
        s.answers.getOrDefault(
          st.source.encoded, Inspection(kind: ikUnavailable, reason: "no such source")
        ),
      )
    of dsRetained:
      d.supplyRetained(st.record, Result[void, string].ok())
    of dsTurn:
      discard
    of dsDone:
      result.outcome = st.outcome
      break
  result.counters = d.counters
  result.turns = d.turns
  result.work = d.work
  # [G455] Then the run is released, a turn at a time, as the engine does after its reply.
  while true:
    let start = getMonoTime()
    let cpu0 = cpuTime()
    let freed = d.release()
    let cpu = cpuTime() - cpu0
    let took = getMonoTime() - start
    inc result.releases
    result.releaseTotal += took
    result.releaseTotalCpu += cpu
    if took > result.longestRelease:
      result.longestRelease = took
    if cpu > result.longestReleaseCpu:
      result.longestReleaseCpu = cpu
    if freed:
      break

func mostConsidered*(c: ResolverCounters): int =
  ## The candidates charged to the name charged most.
  for (_, n) in c.considered:
    result = max(result, n)
