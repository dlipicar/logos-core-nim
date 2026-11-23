## The resolution driver (Tier 5 steps 5-3b and 5-3c-2; DECISIONS G405 as
## amended by G455; docs/PACKAGE-MANAGER.md §4; PACKAGE MANAGER §11,
## l.1294-1295, l.1308-1310).
##
## The resolver (`package/resolver.nim`) runs as a resumable run
## (`startRun`, G455): it suspends where it needs a source's inspection, where
## it needs an installed record's retained-bytes answer, and where its turn's
## work is spent. The driver holds the run for the operation's life:
## - `step` resumes it and says why it stopped: `dsNeed` a source, `dsRetained`
##   a record's retained bytes, `dsTurn` (the turn is spent: step again in a
##   later turn) or `dsDone` with the outcome;
## - `supply` and `supplyRetained` hand the answers to the run, which goes on
##   from where it stopped.
## So the sources retrieved are exactly those one synchronous run reaches, in
## its order, and no unreached candidate's material is needed (PM l.1294-1295,
## l.1310). Nothing is rerun and no answer is a placeholder. A retrieval that
## fails is supplied as `ikUnavailable`, and the run fails
## `package-unavailable`, never as if the candidate were invalid
## (PM l.1308-1309).
##
## Once the outcome is given, `release` frees what the run holds a turn at a
## time (G455): at the maxima it is gigabytes, and dropping it at once would
## hold the module thread for seconds. A run given up before its outcome is
## released the same way.
##
## A `nix` source is not an LGX operation's candidate (`unsupported-source`,
## as `lgxInspector` answers): no realization profile for it is built
## (PM l.886-887), so it is never retrieved; the driver answers it itself.

{.push raises: [].}

import results
import ../package/[errors, records, resolver]

export results, resolver

type
  DriverStepKind* = enum
    dsNeed ## retrieve and inspect `source`, then `supply` it and step again
    dsRetained
      ## check the retained bytes of the installed record `record`, then
      ## `supplyRetained` the answer and step again (5-5 answers it)
    dsTurn ## the turn's work is spent: step again in a later turn
    dsDone ## the operation's outcome

  DriverStep* = object
    case kind*: DriverStepKind
    of dsNeed:
      source*: PackageSource
    of dsRetained:
      record*: int
    of dsTurn:
      discard
    of dsDone:
      outcome*: Result[Resolution, PackageError]

  Driver* = ref object
    run: ResolverRun
    done: bool ## the outcome was given, or the run given up
    runs*: int ## `step` calls
    turns*: int ## steps that ended with the turn spent
    counters*: ResolverCounters ## the run's, once it is done
    work*: int64 ## the work units the run counted, once it is done

proc noRetained(p: InstalledPackage): Result[void, string] {.gcsafe, raises: [].} =
  ## Never called: the run asks for each answer (`dsRetained`).
  err("no installed state")

proc initDriver*(
    catalog: openArray[CatalogEntry],
    trust: TrustInput,
    limits: ResolverLimits,
    root: RootReference,
    budget = ResolverTurnWork,
    operationEntries = Opt.none(int),
): Driver =
  ## [G455] `budget` is the work of one turn (`ResolverTurnWork`, a constant;
  ## the tests give others). 5-3b and 5-3c resolve against no installed state
  ## (5-5 adds it). [G477] `operationEntries` is the operation bound
  ## (`ResolverInput.operationEntries`; 5-5 passes `operation_entries`).
  let input = ResolverInput(
    catalog: @catalog,
    limits: limits,
    trust: trust,
    retained: noRetained,
    operationEntries: operationEntries,
  )
  Driver(run: startRun(input, root, budget))

proc step*(d: Driver): DriverStep =
  ## Resumes the run until it needs something, its turn is spent or it ends.
  doAssert not d.done, "a driver is not stepped after its outcome"
  inc d.runs
  while true:
    var s = d.run.resume()
    case s.kind
    of suNeedSource:
      if s.source.kind != skLgx:
        d.run.supply(
          s.source,
          Inspection(
            kind: ikIneligible,
            error: packageError(
              pecUnsupportedSource,
              "an LGX operation does not use a " & $s.source.kind & " source",
            ),
          ),
        )
        continue
      return DriverStep(kind: dsNeed, source: s.source)
    of suNeedRetained:
      return DriverStep(kind: dsRetained, record: s.record)
    of suTurn:
      inc d.turns
      return DriverStep(kind: dsTurn)
    of suDone:
      d.counters = d.run.counters
      d.work = d.run.work
      d.done = true
      # Moved, not copied: a closure at the maxima holds millions of edges.
      return DriverStep(kind: dsDone, outcome: move s.outcome)

proc supply*(d: Driver, source: PackageSource, inspection: sink Inspection) =
  ## The inspection of a source a `dsNeed` step named, taken, not copied.
  d.run.supply(source, inspection)

proc supplyRetained*(d: Driver, record: int, answer: Result[void, string]) =
  ## The retained-bytes answer for the record a `dsRetained` step named.
  d.run.supplyRetained(record, answer)

func supplied*(d: Driver): int =
  ## The inspections supplied so far.
  if d.run.isNil: 0 else: d.run.supplied

proc release*(d: Driver): bool =
  ## [G455] After the outcome, or to give the run up: frees one turn's work of
  ## what it holds; true once all is freed. No step follows.
  d.done = true
  if d.run.isNil:
    return true
  if d.run.release():
    d.run = nil
    return true
  false

type Retrieve* = proc(source: PackageSource): Inspection {.gcsafe, raises: [].}

proc drive*(d: Driver, retrieve: Retrieve): Result[Resolution, PackageError] =
  ## Every step at once, each source through `retrieve`: the synchronous use,
  ## for tools and tests.
  while true:
    let s = d.step()
    case s.kind
    of dsNeed:
      d.supply(s.source, retrieve(s.source))
    of dsRetained:
      d.supplyRetained(s.record, noRetained(InstalledPackage()))
    of dsTurn:
      discard
    of dsDone:
      return s.outcome

{.pop.}
