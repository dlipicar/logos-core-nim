## The resolution driver (Tier 5 step 5-3b; DECISIONS G405;
## docs/PACKAGE-MANAGER.md §4; PACKAGE MANAGER §11, l.1294-1295, l.1308-1310).
##
## The resolver (`package/resolver.nim`) asks its `Inspector` synchronously;
## retrieval is a sequence of calls on a route. The driver bridges the two
## without changing the resolver:
## - it runs the resolver with an Inspector over a memo of inspections, keyed
##   by the source record's deterministic-CBOR bytes;
## - the first source the memo lacks is recorded and answered `ikUnavailable`,
##   so that run fails `package-unavailable` at that candidate; the driver
##   discards the run's result and asks for that source (`dsNeed`);
## - once the inspection is supplied (`supply`), the next run reaches the same
##   candidate with every earlier answer unchanged, since the resolver is
##   deterministic, and goes further.
## So the sources retrieved are exactly those one synchronous run reaches, in
## its order, and no unreached candidate's material is needed (PM l.1294-1295,
## l.1310). A retrieval that fails is supplied as `ikUnavailable`, and the
## final run fails `package-unavailable`, never as if the candidate were
## invalid (PM l.1308-1309). Each run supplies one new source, so there are at
## most one more runs than catalog entries.
##
## A `nix` source is not an LGX operation's candidate (`unsupported-source`,
## as `lgxInspector` answers): no realization profile for it is built
## (PM l.886-887), so it is never retrieved.

{.push raises: [].}

import std/tables
import results
import ../package/[errors, records, resolver]

export results, resolver

type
  Memo = ref object
    answers: Table[seq[byte], Inspection]
    miss: Opt[PackageSource]

  DriverStepKind* = enum
    dsNeed ## retrieve and inspect `source`, then `supply` it and step again
    dsDone ## the operation's outcome

  DriverStep* = object
    case kind*: DriverStepKind
    of dsNeed:
      source*: PackageSource
    of dsDone:
      outcome*: Result[Resolution, PackageError]

  Driver* = ref object
    catalog: seq[CatalogEntry]
    trust: TrustInput
    limits: ResolverLimits
    root: RootReference
    memo: Memo
    runs*: int
    counters*: ResolverCounters ## the final run's

proc memoInspector(m: Memo): Inspector =
  result = proc(
      source: PackageSource, trust: TrustInput
  ): Inspection {.gcsafe, raises: [].} =
    if source.kind != skLgx:
      return Inspection(
        kind: ikIneligible,
        error: packageError(
          pecUnsupportedSource,
          "an LGX operation does not use a " & $source.kind & " source",
        ),
      )
    let key = source.encoded
    if key in m.answers:
      return m.answers.getOrDefault(key)
    if m.miss.isNone:
      m.miss = Opt.some(source)
    Inspection(kind: ikUnavailable, reason: "not retrieved yet")

proc noRetained(p: InstalledPackage): Result[void, string] {.gcsafe, raises: [].} =
  ## 5-3b resolves against no installed state (5-5 adds it).
  err("no installed state")

func initDriver*(
    catalog: openArray[CatalogEntry],
    trust: TrustInput,
    limits: ResolverLimits,
    root: RootReference,
): Driver =
  Driver(catalog: @catalog, trust: trust, limits: limits, root: root, memo: Memo())

proc step*(d: Driver): DriverStep =
  ## One run of the resolver over what the memo holds.
  d.memo.miss = Opt.none(PackageSource)
  inc d.runs
  let input = ResolverInput(
    catalog: d.catalog,
    limits: d.limits,
    trust: d.trust,
    inspect: memoInspector(d.memo),
    retained: noRetained,
  )
  var counters: ResolverCounters
  let outcome = resolve(input, d.root, counters)
  if d.memo.miss.isSome:
    return DriverStep(kind: dsNeed, source: d.memo.miss.get)
  d.counters = counters
  DriverStep(kind: dsDone, outcome: outcome)

proc supply*(d: Driver, source: PackageSource, inspection: Inspection) =
  ## The inspection of a source a `dsNeed` step named.
  d.memo.answers[source.encoded] = inspection

func supplied*(d: Driver): int =
  d.memo.answers.len

type Retrieve* = proc(source: PackageSource): Inspection {.gcsafe, raises: [].}

proc drive*(d: Driver, retrieve: Retrieve): Result[Resolution, PackageError] =
  ## Every step at once, each source through `retrieve`: the synchronous use,
  ## for tools and tests.
  while true:
    let s = d.step()
    case s.kind
    of dsNeed:
      d.supply(s.source, retrieve(s.source))
    of dsDone:
      return s.outcome

{.pop.}
