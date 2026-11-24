## PM §11: dependency resolution, sans-I/O. The installed state, the catalog
## entries, the accepted signers and the protected resolver limits are inputs;
## candidate material is reached through an `Inspector` that the caller backs
## with retrieval and verification (`lgxInspector` does it for LGX), and the
## retained bytes of installed records through a `RetainedCheck` that the
## installed store backs. The result is one complete closure, an update that
## changes nothing, or an error: nothing is installed and no input changes.
##
## The search follows PM §11: the unresolved package name first in UTF-8 byte
## order, its satisfying candidates in descending SemVer precedence,
## chronological backtracking, and the four protected limits charged as the
## section defines them. It keeps its frames on the heap and computes depths
## without recursion, so neither the result nor the counters depend on a
## native stack.
##
## [IMPL-DECISION G454] The search state is kept incrementally (Tier 5 step
## 5-3c-1): the unresolved names on a heap, each bound name's depth with a
## trail of what each bind changed, a frame's versions tested as they come and
## a cycle walk pruned by depth. `tests/support/oracle_resolver.nim`, the search
## as 5-3b-2 built it, is the reference `test_resolver` compares it with.
##
## [IMPL-DECISION G455] The search is a resumable run (Tier 5 step 5-3c-2):
## `startRun` makes it and `resume` runs one turn, which ends where the run
## needs an inspection or a retained-bytes answer, where `ResolverTurnWork`
## units of work are spent, or at the outcome. The caller supplies each answer
## and resumes it; `release` then frees what it holds a turn at a time. The
## synchronous `resolve` drives a run with no turn budget, answering each need
## through the input's `inspect` and `retained`. The budget changes no outcome,
## counter or retrieval (PM l.1279-1280).

{.push raises: [].}

import std/[algorithm, hashes, sequtils, sets, tables]
import results
import logos_sdk/cbor
import logos_sdk/base/testhooks
import ./[errors, lgx, manifest, records, reffree, semver, signing, trust]

testHooksMarker("resolver")

export results, errors, records, signing

type
  ResolverLimits* = object
    ## [SPEC PM §11] Protected deployment policy's resolver-limit set. Only
    ## `resolverLimits` and `decodeResolverLimits` make one, so every limit is
    ## present, positive and no greater than its maximum; no package,
    ## manifest, catalog, source or caller input reaches it.
    names: int
    depth: int
    candidates: int
    attempts: int

  InspectionKind* = enum
    ikEligible ## the record satisfies every candidate rule of the operation
    ikIneligible ## a candidate rule fails: the record is excluded
    ikUnavailable ## its material could not be located or materialized

  ContractBytes = object
    ## [IMPL-DECISION G482] An eligible inspection's contracts, each as its
    ## deterministic encoding, back to back in one buffer: contract `k` is
    ## `bytes[ends[k-1] ..< ends[k]]`. A `string`, which refc's channel copies in
    ## one block (G447); the encodings go in two deallocations. Each encoding is
    ## its own range of the manifest's bytes (the decoder accepts only
    ## deterministic ones), so the buffer is at most the manifest's 4 MiB and an
    ## `int32` holds every offset.
    bytes: string
    ends: seq[int32]

  InspectedDependency* = object
    ## [IMPL-DECISION G482] A dependency entry of an eligible inspection: the
    ## manifest's, with the contracts it lists held in the inspection's
    ## encodings, in order (`listedCount`, `contractAt`).
    package*: string
    kind*: RequirementKind
    version*: string
    count: int32 ## how many of the inspection's contracts it lists, in order

  Inspection* = object
    ## What one source record yields for the requested operation.
    ## [IMPL-DECISION G482] It holds no reference (`requireRefFree`), so it
    ## crosses the Package Manager's worker channel as it is. Only
    ## `eligibleInspection` makes one that holds contracts.
    case kind*: InspectionKind
    of ikEligible:
      identity*: PackageIdentity ## the verified manifest's
      commitment*: ManifestCommitment
      dependencies*: seq[InspectedDependency] ## the manifest's, in declaration order
      contracts: ContractBytes
        ## each entry's listed contracts as it lists them, entry by entry, then
        ## [SPEC PM §11 l.1213] the contracts its selected module declarations
        ## provide (`provided`)
      providedAt: int32 ## where the provided ones start in `contracts`
    of ikIneligible:
      error*: PackageError
    of ikUnavailable:
      reason*: string

  InputUnitKind* = enum
    ## [IMPL-DECISION G477] The kinds of input one record holds, as its walk
    ## (`inputUnits`) gives them: the operation bound counts each one, and the
    ## verification cache weighs each in bytes (5-5-3). Each kind's size is
    ## bounded, so a count of them bounds what a record holds.
    iuRecord ## the record itself
    iuDependency ## a dependency entry: its package name and version text
    iuDependencyContract
      ## [SPEC PM §4 l.295] a contract a dependency entry lists: up to about
      ## 22,000 in one entry of a 4 MiB manifest
    iuProvided ## a contract the record provides

  InputUnit* = tuple[kind: InputUnitKind, bytes: int]
    ## [IMPL-DECISION G477] One unit of a record's input, and the bytes of its
    ## variable parts: a record's identity text (and an ineligible record's
    ## message), a dependency entry's package name and version text, or a
    ## contract's deterministic encoding (`encodedSize`).

  Inspector* =
    proc(source: PackageSource, trust: TrustInput): Inspection {.gcsafe, raises: [].}
    ## Locates, materializes and checks one source record: manifest commitment,
    ## realization profile, platform variant, signature (an anchor of `trust`
    ## authorized for the exact package name) and artifacts (PM §11). Called at
    ## most once per source record in one root operation, always with the
    ## resolver input's `trust`.

  RetainedCheck* =
    proc(p: InstalledPackage): Result[void, string] {.gcsafe, raises: [].}
    ## [SPEC PM §11 l.1302-1303] Whether the retained artifact bytes of an
    ## installed record are present and match their signed digests; the error
    ## says what is absent or altered. The installed store backs it (5-5).

  InstalledPackage* = object
    ## What resolution reads from one installed package record. An installed
    ## state holds each identity once (PM §15).
    identity*: PackageIdentity
    commitment*: ManifestCommitment ## the retained manifest commitment
    signer*: PackageSigner ## the retained `package_signer`
    source*: PackageSource
      ## the retained source; never itself a candidate source (PM l.1331)
    modules*: seq[ModuleDeclaration]
      ## the retained selected-variant module declarations (PM l.814-816)
    dependencies*: seq[PackageDependency] ## its manifest's
    resolvedDependencies*: seq[ResolvedDependency] ## its recorded edges

  RootReference* = object
    ## The root of an operation: a package, a source, or both (PM §11, §15).
    package*: Opt[string]
    version*: Opt[string]
    source*: Opt[PackageSource]
    newerThan*: Opt[PackageIdentity]
      ## `update_package`'s `current`: the root is a version strictly greater
      ## (PM §15 l.1701-1707)

  ResolverInput* = object
    installed*: seq[InstalledPackage]
    catalog*: seq[CatalogEntry]
    limits*: ResolverLimits
    trust*: TrustInput
      ## the accepted signers: `inspect` verifies catalog material with it,
      ## and installed records' retained signers are judged by it
    inspect*: Inspector
    retained* {.requiresInit.}: RetainedCheck
      ## required: no default leaves an installed candidate's bytes unchecked
    operationEntries*: Opt[int]
      ## [IMPL-DECISION G477] The operation bound, protected input
      ## (`operation_entries`): how many inputs one root operation may read
      ## (`ResolverCounters.entries`). A count over it, not one equal to it,
      ## ends the operation with `package-unavailable` (PM l.1308-1309), as an
      ## archive over `archive_bytes` does. None: no bound. Not a limit: the
      ## four limits and their counters are untouched (PM l.1279-1280).

  SelectedPackage* = object
    identity*: PackageIdentity
    commitment*: ManifestCommitment
    installed*: bool ## an installed record satisfies it: nothing to materialize
    source*: Opt[PackageSource]
      ## the selected source when one is needed, and the root's selected or
      ## supplied source even when it is installed
    depth*: int
      ## the greatest number of manifest dependency edges on a path from the
      ## root (PM l.1256)
    resolvedDependencies*: seq[ResolvedDependency]
      ## one exact edge per direct manifest dependency, in declaration order

  ResolverCounters* = object
    names*: int ## the largest partial closure
    depth*: int ## the greatest depth of a bound package name during the operation
    considered*: seq[(string, int)] ## candidates charged per package name, by name
    attempts*: int ## candidate-assignment attempts
    limit*: string
      ## [G399; ruling M5] the resolver limit that ended the operation, by its
      ## configuration name (`partial_closure_names`, ...); empty: none. For the
      ## operator's log: a limit is protected policy input (PM l.1514), and
      ## its exhaustion answers `dependency-unavailable` like a missing
      ## dependency (PM l.1501-1502).
    entries*: int
      ## [IMPL-DECISION G477] The inputs read, counted by `inputUnits`: each
      ## record read (a catalog record when its inspection is supplied, an
      ## installed record at its first evaluation), each of its dependency
      ## entries, each contract a dependency entry lists, and each contract it
      ## provides. Each record once in a root operation.
    bound*: string
      ## [IMPL-DECISION G477] `operation_entries` when the operation bound
      ## ended the operation; empty: it did not. For the operator's log: the
      ## bound is protected input (PM l.1514), and the caller's message does
      ## not state it. `limit` stays empty.

  Resolution* = object
    root*: PackageIdentity
    unchanged*: bool
      ## an update found no applicable newer version: `root` is `current` and
      ## `packages` is empty (PM l.1705)
    packages*: seq[SelectedPackage] ## the closure, in package-name byte order
    counters*: ResolverCounters

  SuspensionKind* = enum
    ## [IMPL-DECISION G455] Why a resumable run (`startRun`) handed control back.
    suNeedSource ## inspect `source`, `supply` the inspection, then `resume`
    suNeedRetained
      ## check the retained bytes of the input's installed record `record`,
      ## `supplyRetained` the answer, then `resume`
    suTurn ## the turn's work is spent: `resume` in a later turn
    suDone ## the operation's outcome: the run is over

  Suspension* = object
    case kind*: SuspensionKind
    of suNeedSource:
      source*: PackageSource
    of suNeedRetained:
      record*: int ## an index into the input's `installed`
    of suTurn:
      discard
    of suDone:
      outcome*: Result[Resolution, PackageError]

# An inspection's contracts (G482) ----------------------------------------------------

requireRefFree(Inspection)

when defined(lcnTestHooks):
  var inspectionBytesForTests* {.threadvar.}: int
    ## Test hook (D27; DECISIONS I89) [IMPL-DECISION G482] (5-3c-4): when not 0, the most
    ## encoded bytes `eligibleInspection` takes instead of `high(int32)`, so a suite reaches
    ## its guard without 2 GiB of contracts. Inert at 0; set by a suite on its own thread.

func eligibleInspection*(
    identity: PackageIdentity,
    commitment: ManifestCommitment,
    deps: openArray[PackageDependency],
    provides: openArray[CborValue],
): Inspection =
  ## [IMPL-DECISION G482] An eligible inspection: `deps`, the manifest's
  ## dependencies in declaration order, and `provides`, the contracts the record
  ## provides, each list kept as given. Each contract is encoded once, here (on
  ## the Package Manager's worker), into one buffer sized for all of them, so it
  ## has no slack. `inspection(v, modules)` gives `provided(modules)`, once each.
  var n = provides.len
  var size = 0
  for d in deps:
    n += d.contracts.len
    for c in d.contracts:
      size += encodedSize(c)
  for c in provides:
    size += encodedSize(c)
  var most = int(high(int32))
  when defined(lcnTestHooks):
    {.cast(noSideEffect), cast(gcsafe).}:
      if inspectionBytesForTests != 0:
        most = inspectionBytesForTests
  doAssert size <= most,
    "an inspection's encodings are at most its manifest's size (G482)"
  result = Inspection(kind: ikEligible, identity: identity, commitment: commitment)
  result.dependencies = newSeqOfCap[InspectedDependency](deps.len)
  result.contracts.bytes = newStringOfCap(size)
  result.contracts.ends = newSeqOfCap[int32](n)
  template addContract(c: CborValue) =
    let enc = encodeCbor(c)
    let at = result.contracts.bytes.len
    result.contracts.bytes.setLen(at + enc.len)
    if enc.len > 0:
      copyMem(addr result.contracts.bytes[at], unsafeAddr enc[0], enc.len)
    result.contracts.ends.add(int32(result.contracts.bytes.len))

  for d in deps:
    result.dependencies.add(
      InspectedDependency(
        package: d.package,
        kind: d.kind,
        version: d.version,
        count: int32(d.contracts.len),
      )
    )
    for c in d.contracts:
      addContract(c)
  result.providedAt = int32(result.contracts.ends.len)
  for c in provides:
    addContract(c)

func listedCount*(d: InspectedDependency): int =
  ## [IMPL-DECISION G482] How many contracts the entry lists.
  int(d.count)

func contractCount*(x: Inspection): int =
  ## [IMPL-DECISION G482] The contracts an eligible inspection holds: each
  ## entry's listed ones, entry by entry, then the provided ones.
  x.contracts.ends.len

func providedCount*(x: Inspection): int =
  ## [IMPL-DECISION G482] The contracts it provides (`provided`).
  if x.contracts.ends.len == 0:
    0
  else:
    x.contracts.ends.len - int(x.providedAt)

func contractAt*(x: Inspection, k: int): Slice[int] =
  ## [IMPL-DECISION G482] Where contract `k` (`contractCount`'s order) is in
  ## `contractData`.
  let lo =
    if k == 0:
      0
    else:
      int(x.contracts.ends[k - 1])
  lo .. int(x.contracts.ends[k]) - 1

func contractData*(x: Inspection): lent string =
  ## [IMPL-DECISION G482] The deterministic encodings of an eligible
  ## inspection's contracts, back to back (`contractAt`).
  x.contracts.bytes

iterator contractRanges*(x: Inspection): tuple[entry: int, at: Slice[int]] =
  ## [IMPL-DECISION G482] Each contract an eligible inspection holds, in order,
  ## and where it is in `contractData`: the entry that lists it, or -1 for a
  ## provided one.
  let n = x.contracts.ends.len
  var k = 0
  if n > 0:
    for i, d in x.dependencies:
      for _ in 0 ..< int(d.count):
        yield (i, x.contractAt(k))
        inc k
  while k < n:
    yield (-1, x.contractAt(k))
    inc k

# A record's input units --------------------------------------------------------------

iterator inputUnits*(x: Inspection): InputUnit =
  ## [IMPL-DECISION G477] One inspection's input, unit by unit: the record,
  ## then each dependency entry followed by the contracts it lists, then each
  ## provided contract. [IMPL-DECISION G482] A contract's bytes are its
  ## encoding's length.
  case x.kind
  of ikEligible:
    yield (iuRecord, x.identity.package.len + x.identity.version.len)
    var k = 0
    let n = x.contracts.ends.len
    for d in x.dependencies:
      yield (iuDependency, d.package.len + d.version.len)
      for _ in 0 ..< (if n > 0: int(d.count) else: 0):
        yield (iuDependencyContract, x.contractAt(k).len)
        inc k
    while k < n:
      yield (iuProvided, x.contractAt(k).len)
      inc k
  of ikIneligible:
    yield (iuRecord, x.error.msg.len)
  of ikUnavailable:
    yield (iuRecord, x.reason.len)

iterator inputUnits*(p: InstalledPackage): InputUnit =
  ## [IMPL-DECISION G477] One installed record's input, unit by unit, as an
  ## inspection's: the record, each dependency entry followed by the contracts
  ## it lists, then each contract its module declarations name.
  yield (iuRecord, p.identity.package.len + p.identity.version.len)
  for d in p.dependencies:
    yield (iuDependency, d.package.len + d.version.len)
    for c in d.contracts:
      yield (iuDependencyContract, encodedSize(c))
  for m in p.modules:
    if m.primaryContract.isSome:
      yield (iuProvided, encodedSize(m.primaryContract.get))
    for c in m.implements:
      yield (iuProvided, encodedSize(c))
    for c in m.extends:
      yield (iuProvided, encodedSize(c))

func inputCount*(x: Inspection): int =
  ## [IMPL-DECISION G477] The units one inspection holds
  ## (`ResolverCounters.entries`): the count of its walk, by lengths.
  result = 1
  if x.kind == ikEligible:
    result += x.dependencies.len + x.contracts.ends.len

func inputCount*(p: InstalledPackage): int =
  ## [IMPL-DECISION G477] The units one installed record holds: the count of
  ## its walk, by lengths.
  result = 1 + p.dependencies.len
  for d in p.dependencies:
    result += d.contracts.len
  for m in p.modules:
    result += int(m.primaryContract.isSome) + m.implements.len + m.extends.len

# Limits ----------------------------------------------------------------------------

const
  ResolverLimitKeys* = [
    "assignment_attempts", "candidates_per_name", "dependency_depth",
    "partial_closure_names",
  ]
    ## [IMPL] The keys of the resolver-limit set in protected policy, in Logos
    ## deterministic-CBOR key order.

  MaxResolverLimits* =
    ResolverLimits(names: 4096, depth: 4095, candidates: 4096, attempts: 1_048_576)
    ## [SPEC PM §11 l.1252] [IMPL-DECISION G361] The greatest value supported
    ## for each limit, documented in `docs/CONFORMANCE.md` ("Resolver limits").
    ## 4,096 names cannot make a path longer than 4,095 edges.

func names*(l: ResolverLimits): int =
  l.names

func depth*(l: ResolverLimits): int =
  l.depth

func candidates*(l: ResolverLimits): int =
  l.candidates

func attempts*(l: ResolverLimits): int =
  l.attempts

func resolverLimits*(
    names, depth, candidates, attempts: int64
): Result[ResolverLimits, string] =
  ## [SPEC PM §11 l.1250-1253] Each limit is a positive integer no greater than
  ## its maximum (`MaxResolverLimits`); any other value is a protected-policy
  ## configuration failure, refused before any root operation, not a package
  ## error (PM §14).
  for (what, v, most) in [
    ("partial_closure_names", names, MaxResolverLimits.names),
    ("dependency_depth", depth, MaxResolverLimits.depth),
    ("candidates_per_name", candidates, MaxResolverLimits.candidates),
    ("assignment_attempts", attempts, MaxResolverLimits.attempts),
  ]:
    if v <= 0:
      return err("resolver limit " & what & " is not positive")
    if v > int64(most):
      return err("resolver limit " & what & " is above its maximum " & $most)
  ok(
    ResolverLimits(
      names: int(names),
      depth: int(depth),
      candidates: int(candidates),
      attempts: int(attempts),
    )
  )

func decodeResolverLimits*(v: CborValue): Result[ResolverLimits, string] =
  ## [SPEC PM §11] [IMPL] The resolver-limit set as protected policy carries
  ## it: a map with exactly the `ResolverLimitKeys`, each a positive integer no
  ## greater than its maximum.
  if v.isNil or v.kind != ckMap:
    return err("the resolver-limit set is not a map")
  var found: Table[string, int64]
  for (k, x) in v.entries:
    let name = k.getText.valueOr:
      return err("a resolver-limit key is not text")
    if name notin ResolverLimitKeys:
      return err("unknown resolver limit " & name)
    let n = x.getUint64.valueOr:
      return err("resolver limit " & name & " is not a positive integer")
    if n > uint64(high(int64)):
      return err("resolver limit " & name & " is above its maximum")
    found[name] = int64(n)
  for k in ResolverLimitKeys:
    if k notin found:
      return err("the resolver-limit set omits " & k)
  resolverLimits(
    found.getOrDefault("partial_closure_names"),
    found.getOrDefault("dependency_depth"),
    found.getOrDefault("candidates_per_name"),
    found.getOrDefault("assignment_attempts"),
  )

# Requirements ----------------------------------------------------------------------

func satisfies*(kind: RequirementKind, required, version: string): bool =
  ## [SPEC PM §11] `exact`: identical version text. `compatible`: a normal
  ## release at or above the minimum with the same left-most non-zero
  ## component, so `0.0.x` and `0.0.0` accept only themselves.
  case kind
  of rkExact:
    version == required
  of rkCompatible:
    let pm = parseSemVer(required)
    let pv = parseSemVer(version)
    if pm.isErr or pv.isErr or pm.get.isPrerelease or pv.get.isPrerelease:
      return false
    let (m, v) = (pm.get, pv.get)
    if cmp(v, m) < 0:
      false
    elif m.major != "0":
      v.major == m.major
    elif m.minor != "0":
      v.major == "0" and v.minor == m.minor
    else:
      v.major == "0" and v.minor == "0" and v.patch == m.patch

func satisfies*(d: PackageDependency, version: string): bool =
  satisfies(d.kind, d.version, version)

func provided*(modules: openArray[ModuleDeclaration]): seq[CborValue] =
  ## [SPEC PM §11 l.1213] The contracts a package provides: every commitment a
  ## module declaration names as its `primary_contract`, in `implements` or in
  ## `extends`, once each, in declaration order. For a candidate the list is
  ## its selected variant's declarations (RG-7).
  var seen: HashSet[seq[byte]]
  for m in modules:
    var named: seq[CborValue]
    if m.primaryContract.isSome:
      named.add(m.primaryContract.get)
    named.add(m.implements)
    named.add(m.extends)
    for c in named:
      if not seen.containsOrIncl(encodeCbor(c)):
        result.add(c)

# The search state ------------------------------------------------------------------

type
  Span = object
    ## [IMPL-DECISION G455] (5-3c-3) A run of contract numbers in one read
    ## record's list (`Resolver.lists`), read in place: requirements and
    ## candidates hold one instead of a copy of the contracts.
    list: int32 ## the record's list; -1: none
    at, len: int32

  Numbers = object
    ## [IMPL-DECISION G455] (5-3c-3) One read record's contracts, numbered:
    ## each dependency entry's as it lists them, then the contracts the record
    ## provides, once each and in ascending number order.
    list: seq[int32]
    entryAt: seq[int32]
      ## where each dependency entry's contracts start in `list`, then where the
      ## provided ones start: one more than the entries

  InternNeed = object
    ## [IMPL-DECISION G455] (5-3c-3) A record read within the operation bound
    ## whose contracts are not numbered yet.
    installed: int ## the installed record, or -1: the catalog record of `source`
    source: seq[byte] ## the catalog record's source encoding

  Req = object
    kind: RequirementKind
    version: string
    pin: Opt[ManifestCommitment]
      ## [SPEC PM §11 l.1304] the commitment of an installed dependent's
      ## recorded edge
    contracts: Span ## [SPEC PM §11 l.1215] the numbers of the contracts it lists

  NameId = int32
    ## [IMPL-DECISION G454] A package name's number in one run (Fable F5): the
    ## catalog's and the installed state's names in byte order, then each name
    ## a bound manifest names first. Lists hold numbers; every order is the
    ## names' bytes, whatever their numbers.

  Cand = object
    identity: PackageIdentity
    commitment: ManifestCommitment
    installed: bool
    source: Opt[PackageSource]
    depNames: seq[string]
    depIds: seq[NameId] ## `depNames`' numbers, set when it is bound
    deps: seq[Req]
    edges: Opt[seq[ResolvedDependency]] ## an installed candidate's recorded edges
    provides: Span ## the numbers of the contracts it provides, ascending

  CatalogPick = object
    commitment: ManifestCommitment
    source: PackageSource
    deps: seq[InspectedDependency]
    numbers: int32 ## its record's numbers (`Resolver.lists`)
    provides: Span ## the numbers of the contracts it provides, ascending

  Eval = object
    picks: seq[CatalogPick]
      ## every eligible catalog record of the identity, in ascending source
      ## encoding
    installed: int ## the installed record of the identity, or -1
    installedError: Opt[PackageError] ## why that record is ineligible
    errors: seq[PackageError] ## every ineligible catalog record's reason, in order

  Frame = object
    id: NameId
    next: int
      ## the next of the name's versions to test against its requirements,
      ## which do not change while the frame is on the stack (G454)
    depth: int ## the name's depth, -1 until a version is first tried
    bound: bool
    # [IMPL-DECISION G455] (5-3c-3) What its requirements ask of every
    # candidate, gathered once when it is pushed (`needSteps`):
    need: seq[int32] ## the contracts they list, once each
    pin: Opt[ManifestCommitment] ## the first commitment they pin
    pinConflict: bool ## they pin two commitments: no candidate is allowed

  Bind = object
    id: NameId
    trail: int ## where the depth changes of its propagation start on `trail`
    linked: bool ## it passed both checks: its edges are in `kids`

  Blocks[T] = object
    ## [IMPL-DECISION G455] (5-3c-3) A list kept in blocks of `BlockLen`: it
    ## grows without copying what it holds, so no append is a step of its
    ## length.
    blocks: seq[seq[T]]
    len: int

  Resolver {.acyclic.} = object
    ## [IMPL-DECISION G455] Acyclic: it holds no reference back to its run or
    ## its steps (rule I6), and what it holds of CBOR values are trees. So ORC
    ## and refc never trace it for cycles: the dependency lists it holds would
    ## make each collection cost their total, on the module thread.
    installed: seq[InstalledPackage]
    catalog: seq[CatalogEntry]
    limits: ResolverLimits
    trust: TrustInput
    installedAt: Table[(string, string), int]
    entries: Table[(string, string), seq[int]] ## by ascending source encoding
    inspected: Table[seq[byte], Inspection]
      ## [IMPL-DECISION G455] the inspections supplied so far, by source encoding
    retainedAnswers: Table[int, Result[void, string]]
      ## the retained-bytes answers supplied so far, by installed record
    evals: seq[Eval] ## the completed evaluations, read in place
    evalAt: Table[(string, string), int] ## by identity, the index in `evals`
    partial: Table[(string, string), (Eval, int)]
      ## [Fable F4] an evaluation that waits for an inspection: what it has
      ## found, and the index of the record it waits for
    # By name number (G454):
    ids: Table[string, NameId]
    names: seq[string]
    versions: seq[seq[string]] ## descending SemVer precedence
    reqs: seq[seq[Req]]
    parents: seq[seq[NameId]] ## the bound names that require it, in step with `reqs`
    kids: seq[seq[NameId]] ## a bound name's bound dependencies
    depth: seq[int32] ## a bound name's depth (PM l.1256)
    cands: seq[Cand] ## a bound name's candidate
    bound: seq[bool]
    seenAt, parentAt, changedAt: seq[uint32] ## marks, by `epoch`
    boundCount: int
    epoch: uint32
    unresolved: seq[NameId]
      ## a binary min-heap by name bytes: every required and unbound name is in
      ## it; an entry that no longer is one is dropped when it reaches the top
    binds: seq[Bind]
    trail: seq[(NameId, int32)] ## (name, its depth before the bind)
    buckets: seq[seq[NameId]] ## propagation's queue, by depth before the bind
    bucketLo, bucketHi: int ## the buckets the current propagation uses
    walk: seq[NameId]
    work: int64
      ## [IMPL-DECISION G454] the work units counted so far (5-3c's plan §3.6):
      ## each O(1) or O(log n), the same total for the same inputs
    checkedAt: int64 ## the work count at the last turn check
    largestStep: int64
      ## [IMPL-DECISION G455] (5-3c-3) the most work between two turn checks:
      ## what one turn can overrun its budget by
    # [IMPL-DECISION G455] (5-3c-3) Contracts, numbered once in a run, by their
    # deterministic encoding (the equality the oracle pins):
    encodings: Blocks[seq[byte]] ## by number, its encoding
    hashes: Blocks[Hash] ## by number, its encoding's hash
    slots: seq[seq[int32]]
      ## open addressing over the numbers, one more than each (0: free), in
      ## blocks of `BlockLen` (one shorter while there are fewer slots), each
      ## allocated when first written: an unallocated block's slots are free
    slotCount: int ## the slots, a power of two
    oldSlots: seq[seq[int32]]
      ## the slots before their last growth, while the numbers move out of
      ## them a few at a time: a growth moves none at once
    oldCount: int ## their count; 0: none
    moved: int ## the numbers moved out of `oldSlots`, in number order
    marks: Blocks[uint32] ## by number, a deduplication's epoch
    markEpoch: uint32
    lists: seq[Numbers] ## the read records' numbers
    numbered: Table[seq[byte], int32]
      ## by catalog source encoding, its record's numbers (`lists`)
    installedNumbers: seq[int32]
      ## by installed record, one more than its numbers' index (0: not yet)
    intern: Opt[InternNeed] ## a record read whose contracts are not numbered yet
    allowed: seq[int] ## `allowSteps`' answer: the picks a candidate may take
    installedCovers: bool ## `allowSteps`' answer: the installed record does
    root: NameId
    charged: HashSet[(string, string)]
    considered: Table[string, int]
    attempts: int
    maxNames: int
    maxDepth: int
    tripped: string ## the limit that ended the run (`ResolverCounters.limit`)
    # [IMPL-DECISION G477] The operation bound:
    entryBound: int ## `operationEntries`, or `high(int)` for none
    inputsRead: int ## the inputs read (`ResolverCounters.entries`)
    installedRead: seq[bool] ## by installed record: counted
    stopped: string ## the bound that ended the run (`ResolverCounters.bound`)
    # [IMPL-DECISION G455] The resumable run:
    stack: seq[Frame] ## the search's frames, kept across suspensions
    miss: Opt[Suspension]
      ## what the search needs before it can go on: an inspection or a
      ## retained-bytes answer not supplied yet
    turnEnd: int64 ## the work count at which the turn is spent
    bindOk: bool ## `bindSteps`' answer: both checks passed
    settled: Opt[PackageError] ## `settleSteps`' answer: the depth limit's error
    version: Opt[string] ## `versionSteps`' answer: the frame's next version
    resolution: Resolution ## `closureSteps`' answer
    ended: bool ## the run gave its outcome (rule I5)

  RunSteps = iterator (): Suspension {.closure, gcsafe, raises: [].}
    ## [IMPL-DECISION G455] A resumable run's steps (5-3c's plan §3.5, rules I1
    ## to I6): made by a factory that captures what it needs once (I1), never
    ## resumed after `suDone` (I5), and held by its driver, never by the
    ## resolver (I6).

func key(id: PackageIdentity): (string, string) =
  (id.package, id.version)

func unavailableDependency(msg: string): PackageError =
  packageError(pecDependencyUnavailable, msg)

func invalidRequest(msg: string): PackageError =
  packageError(pecInvalidRequest, msg)

func full(l: int): bool =
  ## Whether a list of `l` elements, grown by appends, is at its capacity:
  ## Nim's are four, then each doubled up to 32,768, then each grown by half
  ## (`resize` in Nim's `system/strs_v2.nim`, which sequences use too). A list
  ## shortened and grown again is counted as if it were not: the count is the
  ## same for the same inputs, which is what it needs.
  if l < 4:
    return false
  if l <= 32_768:
    return (l and (l - 1)) == 0
  var c = 32_768
  while c < l:
    c = c div 2 + c
  c == l

proc newId(r: var Resolver, name: string): NameId =
  ## Numbers `name`, which has no number yet.
  result = NameId(r.names.len)
  r.ids[name] = result
  r.names.add(name)
  r.versions.add(@[])
  r.reqs.add(@[])
  r.parents.add(@[])
  r.kids.add(@[])
  r.depth.add(0)
  r.cands.add(Cand())
  r.bound.add(false)
  r.seenAt.add(0)
  r.parentAt.add(0)
  r.changedAt.add(0)

proc idOf(r: var Resolver, name: string): NameId =
  ## The name's number, given now if it has none.
  result = r.ids.getOrDefault(name, -1)
  if result < 0:
    result = r.newId(name)

func before(r: Resolver, a, b: NameId): bool =
  r.names[a] < r.names[b]

proc push(r: var Resolver, x: NameId) =
  ## [IMPL-DECISION G455] A heap operation counts each level it moves through,
  ## and the heap's growth: with the 80,000 names of a maximum-size manifest
  ## on the heap, one push or pop counted as one unit made up to about 30
  ## string comparisons.
  inc r.work
  if full(r.unresolved.len):
    r.work += int64(r.unresolved.len)
  r.unresolved.add(x)
  var i = r.unresolved.high
  while i > 0:
    inc r.work
    let p = (i - 1) div 2
    if not r.before(r.unresolved[i], r.unresolved[p]):
      break
    swap(r.unresolved[i], r.unresolved[p])
    i = p

proc popTop(r: var Resolver) =
  inc r.work
  let last = r.unresolved.pop()
  let n = r.unresolved.len
  if n == 0:
    return
  r.unresolved[0] = last
  var i = 0
  while true:
    inc r.work # [G455] a level, as `push`'s
    let l = 2 * i + 1
    if l >= n:
      break
    var c = l
    if l + 1 < n and r.before(r.unresolved[l + 1], r.unresolved[l]):
      c = l + 1
    if not r.before(r.unresolved[c], r.unresolved[i]):
      break
    swap(r.unresolved[i], r.unresolved[c])
    i = c

proc nextUnresolved(r: var Resolver): Opt[NameId] =
  ## [SPEC PM §11] The unresolved package name first in UTF-8 byte order: the
  ## heap's top once the entries that are no longer unresolved are dropped.
  while r.unresolved.len > 0:
    let top = r.unresolved[0]
    if r.reqs[top].len > 0 and not r.bound[top]:
      return Opt.some(top)
    r.popTop()
  Opt.none(NameId)

proc initResolver(r: var Resolver, input: sink ResolverInput) =
  ## The resolver over `input`, taken, not copied. [IMPL-DECISION G455] The
  ## rest of G454's setup is the run's first steps (`setupSteps`).
  let l = input.limits
  doAssert l.names > 0 and l.depth > 0 and l.candidates > 0 and l.attempts > 0 and
    l.names <= MaxResolverLimits.names and l.depth <= MaxResolverLimits.depth and
    l.candidates <= MaxResolverLimits.candidates and
    l.attempts <= MaxResolverLimits.attempts,
    "resolver limits come from resolverLimits or decodeResolverLimits"
  doAssert input.operationEntries.get(1) > 0, "the operation bound is positive"
  var input = input
  r = Resolver(
    installed: move input.installed,
    catalog: move input.catalog,
    limits: l,
    trust: move input.trust,
    entryBound: input.operationEntries.get(high(int)),
    turnEnd: high(int64),
  )
  r.buckets.setLen(l.depth + 1)
  r.installedRead.setLen(r.installed.len)
  r.installedNumbers.setLen(r.installed.len)

func pending(): PackageError =
  ## [IMPL-DECISION G455] What a helper returns when the search needs something
  ## not supplied yet (`miss` says what): the run suspends and calls it again,
  ## so this error is never an outcome.
  packageError(pecPackageUnavailable, "not supplied yet")

proc countRead(r: var Resolver, units: int) =
  ## [IMPL-DECISION G477] Counts `units` inputs read toward the operation
  ## bound.
  r.inputsRead += units

proc pastBound(r: var Resolver): Result[void, PackageError] =
  ## [IMPL-DECISION G477] The operation bound's stop, once the inputs read
  ## pass it: [SPEC PM §11 l.1308-1309] the material needed to resolve the
  ## closure cannot be materialized here, which proves nothing about any
  ## candidate or closure. The message does not state the bound (PM l.1514).
  if r.inputsRead <= r.entryBound:
    return ok()
  r.stopped = "operation_entries"
  err(
    packageError(
      pecPackageUnavailable,
      "the operation reads more package records and entries than this deployment allows",
    )
  )

proc inspectSource(
    r: var Resolver, s: PackageSource
): Result[ptr Inspection, PackageError] =
  ## [IMPL-DECISION G455] The supplied inspection of `s`, read in place: a
  ## copy of one with a maximum-size manifest took milliseconds. Nil, with the
  ## need noted, until one is supplied. Each source is asked for at the point
  ## a synchronous run would inspect it, and once (`Inspector`). The caller
  ## is done with it before anything is supplied.
  ##
  ## [IMPL-DECISION G477] Its inputs were counted when it was supplied: past
  ## the operation bound, reading it ends the operation.
  let k = s.encoded
  r.inspected.withValue(k, v):
    ?r.pastBound()
    return ok(v)
  r.miss = Opt.some(Suspension(kind: suNeedSource, source: s))
  ok(nil)

proc takeMiss(r: var Resolver): Suspension =
  result = r.miss.get
  r.miss = Opt.none(Suspension)

# Contracts, numbered (5-3c-3) --------------------------------------------------------

const
  FirstContractSlots = 64
  BlockBits = 12
  BlockLen = 1 shl BlockBits
  BlockMask = BlockLen - 1

template at(b: Blocks, i: int): untyped =
  b.blocks[i shr BlockBits][i and BlockMask]

proc add[T](b: var Blocks[T], x: sink T) =
  if (b.len and BlockMask) == 0:
    b.blocks.add(newSeqOfCap[T](BlockLen))
  b.blocks[^1].add(x)
  inc b.len

proc dropLast[T](b: var Blocks[T]) =
  b.blocks[^1].setLen(b.blocks[^1].len - 1)
  dec b.len
  if b.blocks[^1].len == 0:
    b.blocks.setLen(b.blocks.len - 1)

func slotAt(slots: seq[seq[int32]], i: int): int32 {.inline.} =
  if slots[i shr BlockBits].len == 0:
    0
  else:
    slots[i shr BlockBits][i and BlockMask]

func entrySpan(r: Resolver, list: int32, i: int): Span =
  ## Dependency entry `i`'s contracts in a record's numbers. A record with no
  ## contracts keeps no `entryAt` (`internSteps`): every span of it is empty.
  template l(): untyped =
    r.lists[list].entryAt

  if l.len == 0:
    return Span(list: list, at: 0, len: 0)
  Span(list: list, at: l[i], len: l[i + 1] - l[i])

func providedSpan(r: Resolver, list: int32): Span =
  ## The contracts a record provides, in its numbers.
  if r.lists[list].entryAt.len == 0:
    return Span(list: list, at: 0, len: 0)
  let at = r.lists[list].entryAt[^1]
  Span(list: list, at: at, len: int32(r.lists[list].list.len) - at)

func lookup(r: Resolver, s: Span, x: int32): (bool, int) =
  ## [IMPL-DECISION G455] (5-3c-3) Whether the ascending span holds `x`, by
  ## binary search, and the probes it made (one at least): the work is the
  ## steps walked.
  result[1] = 1
  if s.list < 0:
    return
  var lo = int(s.at)
  var hi = int(s.at) + int(s.len)
  while lo < hi:
    inc result[1]
    let mid = (lo + hi) shr 1
    let v = r.lists[s.list].list[mid]
    if v == x:
      result[0] = true
      return
    if v < x:
      lo = mid + 1
    else:
      hi = mid

type
  Cursor = object
    ## Where `internSteps` is in a record: `stage` 0 is its dependency entries
    ## (entry `i`, contract `j`); for a catalog record 1 is its provided
    ## contracts, and for an installed record 1 to 3 are module `i`'s primary
    ## contract, `implements` and `extends`; 4 is the end. `k` is a catalog
    ## record's next contract in the walk's encodings (G482).
    stage, i, j, k: int

  ContractStep = enum
    csDone ## the record's contracts are all numbered
    csEntry ## the walk moved to another entry or module: a unit
    csContract ## a contract: its encoding

template dependencyStage(deps: untyped, listed: untyped, contract: untyped) =
  if c.i >= deps.len:
    nums.entryAt.add(int32(nums.list.len)) # where the provided ones start
    c.stage = 1
    c.i = 0
    c.j = 0
    return csEntry
  if c.j == 0 and nums.entryAt.len == c.i:
    nums.entryAt.add(int32(nums.list.len))
    return csEntry
  if c.j < listed:
    contract
    inc c.j
    return csContract
  inc c.i
  c.j = 0
  return csEntry

proc nextCatalog(
    x: Inspection,
    walk: ContractBytes,
    c: var Cursor,
    nums: var Numbers,
    at: var Slice[int],
): ContractStep =
  ## [IMPL-DECISION G482] A catalog record's next contract: where its encoding
  ## is in `walk`, the record's encodings, which the walk took from the
  ## inspection when it started. `x` gives the entries' counts.
  template next() =
    at = (if c.k == 0: 0 else: int(walk.ends[c.k - 1])) .. int(walk.ends[c.k]) - 1
    inc c.k

  case c.stage
  of 0:
    dependencyStage(x.dependencies, int(x.dependencies[c.i].count), next())
  of 1:
    if c.k < walk.ends.len:
      next()
      return csContract
    c.stage = 4
    return csEntry
  else:
    return csDone

proc nextInstalled(
    p: InstalledPackage, c: var Cursor, nums: var Numbers, enc: var seq[byte]
): ContractStep =
  ## An installed record's next contract, encoded: each its dependency
  ## entries list, then each its module declarations name (PM l.1213).
  template encodeNext() =
    enc = encodeCbor(p.dependencies[c.i].contracts[c.j])

  case c.stage
  of 0:
    dependencyStage(p.dependencies, p.dependencies[c.i].contracts.len, encodeNext())
  of 1, 2, 3:
    if c.i >= p.modules.len:
      c.stage = 4
      return csEntry
    template m(): untyped =
      p.modules[c.i]

    if c.stage == 1:
      c.stage = 2
      c.j = 0
      if m.primaryContract.isSome:
        enc = encodeCbor(m.primaryContract.get)
        return csContract
      return csEntry
    if c.stage == 2:
      if c.j < m.implements.len:
        enc = encodeCbor(m.implements[c.j])
        inc c.j
        return csContract
      c.stage = 3
      c.j = 0
      return csEntry
    if c.j < m.extends.len:
      enc = encodeCbor(m.extends[c.j])
      inc c.j
      return csContract
    c.stage = 1
    c.j = 0
    inc c.i
    return csEntry
  else:
    return csDone

const EntryStepsPerLookup = 32
  ## [IMPL-DECISION G455] (5-3c-3) The most walk steps `nextContract` takes
  ## for one lookup of a catalog record.

proc nextContract(
    r: var Resolver,
    need: InternNeed,
    walk: ContractBytes,
    c: var Cursor,
    nums: var Numbers,
    enc: var seq[byte],
    at: var Slice[int],
    steps: var int,
): ContractStep =
  ## [IMPL-DECISION G455] (5-3c-3) The next steps of `internSteps`' walk, up to
  ## and with its next contract: `steps` of them, each a unit. An installed
  ## record's contract is encoded into `enc`; a catalog record's is the range
  ## `at` of `walk` (G482). A catalog record is looked up for each call, for
  ## its entries' counts, so no view of the table is held across a yield (rule
  ## I2); one lookup takes up to `EntryStepsPerLookup` steps, none of which
  ## yields, so an entry that lists nothing costs no lookup of its own.
  steps = 1
  if need.installed >= 0:
    return nextInstalled(r.installed[need.installed], c, nums, enc)
  result = csDone
  steps = 0
  r.inspected.withValue(need.source, v):
    while true:
      result = nextCatalog(v[], walk, c, nums, at)
      inc steps
      if result != csEntry or steps >= EntryStepsPerLookup:
        break

func listsNoContract(x: Inspection): bool =
  ## [IMPL-DECISION G455] (5-3c-3) Whether an eligible catalog record lists and
  ## provides no contract. [IMPL-DECISION G482] By its encodings' count.
  x.contracts.ends.len == 0

func listsNoContract(p: InstalledPackage): bool =
  ## Whether an installed record lists and declares no contract.
  for d in p.dependencies:
    if d.contracts.len > 0:
      return false
  for m in p.modules:
    if m.primaryContract.isSome or m.implements.len > 0 or m.extends.len > 0:
      return false
  true

proc numberedEmpty(r: var Resolver, need: InternNeed, walked: int): int32 =
  ## [IMPL-DECISION G455] (5-3c-3) Numbers a record that lists and provides no
  ## contract, in place and in the step that reads it, as `internSteps` would:
  ## its numbers are empty, and so is every span of them (`entrySpan`). The
  ## walk that found none read the length of each of its `walked` entries and
  ## modules: a unit, and one for each 16 of them (each read costs far less
  ## than a unit); a growth of the lists is counted too. The next check ends
  ## the turn.
  let l = r.lists.len
  r.work += int64(1 + walked shr 4)
  if full(l):
    r.work += int64(l)
  result = int32(l)
  r.lists.add(Numbers())
  if need.installed >= 0:
    r.installedNumbers[need.installed] = result + 1
  else:
    r.numbered[need.source] = result

func known(r: Resolver, id: PackageIdentity): bool =
  id.key in r.installedAt or id.key in r.entries

proc evaluate(r: var Resolver, id: PackageIdentity): Result[int, PackageError] =
  ## [SPEC PM §11] Candidate eligibility for one exact identity: the installed
  ## record and every catalog record of it, in ascending source-record
  ## encoding. Every reason is kept, the installed record's first. Unavailable
  ## material and altered retained bytes fail the root operation; neither is
  ## ineligibility.
  ##
  ## [IMPL-DECISION G455] A record not supplied yet returns `pending` with the
  ## need noted, and the run calls this again once it is supplied. The
  ## retained check is answered once per record, and what the walk has found
  ## is kept with the index it stopped at (Fable F4), so each record is read
  ## once. The evaluation is the index of the identity's in `evals`, read in
  ## place.
  let at = r.evalAt.getOrDefault(id.key, -1)
  if at >= 0:
    return ok(at)
  var e: Eval
  var next = 0
  var held: (Eval, int)
  if r.partial.pop(id.key, held):
    e = move held[0]
    next = held[1]
  else:
    e = Eval(installed: r.installedAt.getOrDefault(id.key, -1))
    if e.installed >= 0:
      if not r.installedRead[e.installed]:
        # [IMPL-DECISION G477] Counted at its first evaluation, before its
        # retained bytes are asked for: an evaluation that waits for them is
        # made again.
        r.installedRead[e.installed] = true
        r.countRead(r.installed[e.installed].inputCount)
      ?r.pastBound()
      template p(): untyped =
        r.installed[e.installed] # read in place: a copy would copy its lists

      if r.installedNumbers[e.installed] == 0:
        # [IMPL-DECISION G455] (5-3c-3) Its contracts are numbered once it is
        # read within the bound: the evaluation is made again after. Without
        # any, here.
        if p.listsNoContract:
          discard r.numberedEmpty(
            InternNeed(installed: e.installed), p.dependencies.len + p.modules.len
          )
        else:
          r.intern = Opt.some(InternNeed(installed: e.installed))
          return err(pending())

      if not p.commitment.supportsManifestSchema:
        # [SPEC PM §11 l.1217-1218] Ineligible, and not an integrity failure:
        # its retained bytes are not judged.
        e.installedError = Opt.some(
          packageError(
            pecUnsupportedManifest,
            "the installed " & $id &
              " names a manifest schema this revision does not support",
          )
        )
      else:
        if e.installed notin r.retainedAnswers:
          r.miss = Opt.some(Suspension(kind: suNeedRetained, record: e.installed))
          return err(pending())
        r.retainedAnswers.getOrDefault(e.installed).isOkOr:
          # [SPEC PM §11 l.1302-1303]
          return err(
            packageError(pecArtifactIntegrity, "the installed " & $id & ": " & error)
          )
        if not r.trust.accepts(p.signer, id.package):
          # [SPEC PM §11 l.1292-1293] [IMPL-DECISION G166] A withdrawn signer.
          e.installedError = Opt.some(
            packageError(
              pecSignature,
              "the retained signer of the installed " & $id &
                " is not an accepted signer authorized for " & id.package,
            )
          )
  let records = r.entries.getOrDefault(id.key)
  while next < records.len:
    let source = r.catalog[records[next]].source
    let x = ?r.inspectSource(source)
    if x.isNil:
      r.partial[id.key] = (move e, next)
      return err(pending())
    var numbers = -1'i32
    if x[].kind == ikEligible and x[].identity == id:
      let k = source.encoded
      numbers = r.numbered.getOrDefault(k, -1)
      if numbers < 0:
        # [IMPL-DECISION G455] (5-3c-3) Its contracts are numbered once it is
        # read within the bound; the walk goes on from it after. Without any,
        # here.
        if x[].listsNoContract:
          numbers =
            r.numberedEmpty(InternNeed(installed: -1, source: k), x[].dependencies.len)
        else:
          r.intern = Opt.some(InternNeed(installed: -1, source: k))
          r.partial[id.key] = (move e, next)
          return err(pending())
    inc next
    case x[].kind
    of ikUnavailable:
      return err(packageError(pecPackageUnavailable, $id & ": " & x[].reason))
    of ikIneligible:
      e.errors.add(x[].error)
    of ikEligible:
      if x[].identity != id:
        # [SPEC PM §2, §6] The manifest wins over catalog location data.
        e.errors.add(
          packageError(
            pecInvalidPackage, "the manifest declares " & $x[].identity & ", not " & $id
          )
        )
      else:
        # [IMPL-DECISION G455] Its dependency entries are moved, not copied (a
        # copy of a maximum-size manifest's took milliseconds). Nothing reads
        # them again: an identity is evaluated once (`evalAt`), only the
        # identity its manifest declares takes them, and a source root reads
        # its manifest (`sourceRoot`) before anything is evaluated.
        e.picks.add(
          CatalogPick(
            commitment: x[].commitment,
            source: source,
            deps: move x[].dependencies,
            numbers: numbers,
            provides: r.providedSpan(numbers),
          )
        )
  r.evals.add(move e)
  r.evalAt[id.key] = r.evals.high
  ok(r.evals.high)

func firstError(e: Eval): Opt[PackageError] =
  ## [IMPL-DECISION I110] The first-error rule (TF-60 interim): the installed
  ## record's reason, then the catalog records' in source order.
  if e.installedError.isSome:
    e.installedError
  elif e.errors.len > 0:
    Opt.some(e.errors[0])
  else:
    Opt.none(PackageError)

func unsupportedOnly(e: Eval): bool =
  ## Every record of the identity is ineligible, and only because its manifest
  ## schema is unsupported (PM l.1219, l.1707).
  if e.picks.len > 0 or (e.installedError.isNone and e.installed >= 0):
    return false
  if e.installedError.isSome and e.installedError.get.code != pecUnsupportedManifest:
    return false
  e.errors.allIt(it.code == pecUnsupportedManifest) and
    (e.installedError.isSome or e.errors.len > 0)

func fresh[D: PackageDependency | InspectedDependency](
    r: Resolver, deps: seq[D], numbers: int32
): (seq[string], seq[Req]) =
  # [IMPL-DECISION G455] Sized once: growing them took a third of the build of
  # a maximum-size manifest's list. (5-3c-3) A requirement's contracts are a
  # span of its record's numbers: none is copied or encoded. [G482] An
  # installed record's entries or an inspection's: only their package, kind
  # and version are read.
  result[0] = newSeqOfCap[string](deps.len)
  result[1] = newSeqOfCap[Req](deps.len)
  for i, d in deps:
    result[0].add(d.package)
    result[1].add(
      Req(kind: d.kind, version: d.version, contracts: r.entrySpan(numbers, i))
    )

func pinned(edges: seq[ResolvedDependency]): (seq[string], seq[Req]) =
  ## [SPEC PM §11 l.1304] An installed candidate brings its recorded edges as
  ## exact identities and commitments; they are not resolved again, and they
  ## carry no contracts.
  for e in edges:
    result[0].add(e.identity.package)
    result[1].add(
      Req(
        kind: rkExact,
        version: e.identity.version,
        pin: Opt.some(e.commitment),
        contracts: Span(list: -1),
      )
    )

func meetsVersionAndPin(c: Cand, q: Req): bool =
  ## A requirement's version and pin; its contracts are `bindSteps`' walk.
  satisfies(q.kind, q.version, c.identity.version) and
    (q.pin.isNone or q.pin.get == c.commitment)

func allows(f: Frame, c: ManifestCommitment): bool =
  ## [SPEC PM §11 l.1304] Whether the frame's pins allow commitment `c`: it has
  ## none, or one and `c` is it. Two distinct pins allow none, as each excludes
  ## the other.
  f.pin.isNone or (not f.pinConflict and f.pin.get == c)

proc excludedByKnownCommitment(r: var Resolver, id: PackageIdentity, f: int): bool =
  ## [SPEC PM §11 l.1305-1306] Every record of the identity has a known
  ## commitment that frame `f`'s pins exclude: it is neither considered nor
  ## charged. A catalog record not yet inspected has no known commitment.
  ## [IMPL-DECISION G455] (5-3c-3) Its records are read in place: a copy of
  ## an inspection copied its lists.
  if r.stack[f].pin.isNone:
    return false
  let at = r.installedAt.getOrDefault(id.key, -1)
  if at >= 0 and r.stack[f].allows(r.installed[at].commitment):
    return false
  result = true
  r.entries.withValue(id.key, g):
    for i in g[]:
      let k = r.catalog[i].source.encoded
      var known = false
      r.inspected.withValue(k, x):
        known =
          x.kind == ikEligible and x.identity == id and
          not r.stack[f].allows(x.commitment)
      if not known:
        return false

proc dependencyCandidate(
    r: Resolver, f: int, id: PackageIdentity, e: Eval
): Result[Opt[Cand], PackageError] =
  ## [SPEC PM §11 l.1294-1310] The candidate for a reached dependency identity,
  ## after eligibility, the accumulated pins and contracts, commitment
  ## selection and the installed-identity conflict check. [IMPL-DECISION
  ## G455] (5-3c-3) The pins and contracts are `allowSteps`': the picks they
  ## allow (`r.allowed`, indexes in `e.picks`) and whether the installed
  ## record provides the contracts (`r.installedCovers`).
  template allowed(): untyped =
    r.allowed

  for i in allowed:
    if e.picks[i].commitment != e.picks[allowed[0]].commitment:
      # [SPEC PM §11] [IMPL-DECISION G74] No protected catalog policy selects
      # one of several commitments.
      return err(
        unavailableDependency(
          "acceptable manifests claim " & $id &
            " with different commitments, and no protected catalog policy selects one"
        )
      )
  if e.installed >= 0:
    template p(): untyped =
      r.installed[e.installed] # read in place: a copy would copy its lists

    if allowed.len > 0 and e.picks[allowed[0]].commitment != p.commitment:
      # [SPEC PM §11 l.1296-1298] Compared with the installed record whether or
      # not it is eligible; not skipped and not resolved by backtracking.
      return err(
        unavailableDependency(
          $id & " is installed with another manifest commitment than the catalog's"
        )
      )
    let (names, deps) = pinned(p.resolvedDependencies)
    var c = Cand(
      identity: id,
      commitment: p.commitment,
      installed: true,
      depNames: names,
      deps: deps,
      edges: Opt.some(p.resolvedDependencies),
      provides: r.providedSpan(r.installedNumbers[e.installed] - 1),
    )
    if e.installedError.isNone and r.stack[f].allows(p.commitment) and r.installedCovers:
      return ok(Opt.some(c))
    if allowed.len > 0:
      # [IMPL-DECISION I110] B7: an eligible catalog record of the installed
      # commitment satisfies the identity; it stays installed, with its
      # recorded edges and its retained signer (replacing it is PKG-0608's).
      c.provides = e.picks[allowed[0]].provides
      return ok(Opt.some(c))
    return ok(Opt.none(Cand))
  if allowed.len > 0:
    let a = allowed[0]
    let (names, deps) = r.fresh(e.picks[a].deps, e.picks[a].numbers)
    return ok(
      Opt.some(
        Cand(
          identity: id,
          commitment: e.picks[a].commitment,
          source: Opt.some(e.picks[a].source),
          depNames: names,
          deps: deps,
          provides: e.picks[a].provides,
        )
      )
    )
  ok(Opt.none(Cand))

proc rootCandidate(
    r: Resolver, id: PackageIdentity, e: Eval
): Result[Opt[Cand], PackageError] =
  ## The root's edges are always selected afresh from its manifest; whether an
  ## installed record of the root conflicts is the operation's rule (PM §11,
  ## §15).
  for p in e.picks:
    if p.commitment != e.picks[0].commitment:
      return err(
        unavailableDependency(
          "acceptable manifests claim " & $id &
            " with different commitments, and no protected catalog policy selects one"
        )
      )
  if e.picks.len > 0:
    # Read in place: a copy would copy its dependency list.
    let (names, deps) = r.fresh(e.picks[0].deps, e.picks[0].numbers)
    return ok(
      Opt.some(
        Cand(
          identity: id,
          commitment: e.picks[0].commitment,
          installed:
            e.installed >= 0 and
            r.installed[e.installed].commitment == e.picks[0].commitment,
          source: Opt.some(e.picks[0].source),
          depNames: names,
          deps: deps,
          provides: e.picks[0].provides,
        )
      )
    )
  if e.installed >= 0 and e.installedError.isNone:
    template p(): untyped =
      r.installed[e.installed] # read in place: a copy would copy its lists

    let numbers = r.installedNumbers[e.installed] - 1
    let (names, deps) = r.fresh(p.dependencies, numbers)
    return ok(
      Opt.some(
        Cand(
          identity: id,
          commitment: p.commitment,
          installed: true,
          depNames: names,
          deps: deps,
          provides: r.providedSpan(numbers),
        )
      )
    )
  ok(Opt.none(Cand))

template turnCheck(r: ref Resolver) =
  ## [IMPL-DECISION G455] Ends the turn once its work is spent. (5-3c-3) It
  ## keeps the most work counted between two checks (`largestStep`): what one
  ## turn can overrun its budget by, which the suites bound.
  block:
    let d = r.work - r.checkedAt
    if d > r.largestStep:
      r.largestStep = d
    r.checkedAt = r.work
  if r.work >= r.turnEnd:
    yield Suspension(kind: suTurn)

template tick(r: ref Resolver) =
  ## [IMPL-DECISION G455] One work unit (5-3c's plan §3.6). The turn is spent
  ## when the count reaches `turnEnd`, and the run yields there. Only inside a
  ## run's iterators; a helper that is not one counts with `inc r.work`, and the
  ## next unit an iterator counts ends the turn.
  inc r.work
  turnCheck(r)

template spendBy(r: ref Resolver, n: int) =
  ## [IMPL-DECISION G455] `n` work units at once: what copying or freeing a
  ## list of `n` elements costs.
  r.work += int64(n)
  turnCheck(r)

template growing(r: ref Resolver, list: untyped) =
  ## [IMPL-DECISION G455] Before an append: an append to a full list copies
  ## it, so the copy is counted, its length. In a dense closure one bind
  ## appends to thousands of names' lists that fill up together, and their
  ## copies alone held the thread for 0.1 s at 4,096 names.
  block:
    let l = list.len
    if full(l):
      spendBy(r, l)

func nameAt(r: Resolver, installed: int, k: int32): ptr string =
  ## The package name of `k`, an installed record's index or, from
  ## `installed` on, a catalog entry's. Read in place; neither list is resized
  ## while the pointer is used.
  if k < installed:
    r.installed[k].identity.package.unsafeAddr
  else:
    r.catalog[k - installed].identity.package.unsafeAddr

proc setupSteps(r: ref Resolver): RunSteps =
  ## [G454] The setup: the catalog's and the installed state's names numbered
  ## in byte order, each name's versions in descending SemVer precedence, and
  ## each identity's catalog records in ascending source-record encoding, a
  ## record that repeats kept once.
  ##
  ## [IMPL-DECISION G455] It is the run's first steps, counted and sliced as
  ## the search is, since it is linear in the catalog: done at once before the
  ## first turn, it held the module thread for about 0.4 s at the catalog's
  ## 65,536 entries. An entry counts one unit and the bytes it hashes, parses
  ## or encodes. What is not sliced is one sort: of the names (the catalog is
  ## in canonical order, so it is a merge sort's linear case), of one name's
  ## versions, or of one identity's records.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    let ni = r.installed.len
    var known = newSeqOfCap[int32](ni + r.catalog.len)
    var i = 0
    while i < ni + r.catalog.len:
      tick(r)
      known.add(int32(i))
      inc i
    spendBy(r, known.len)
    # By index: the names are not copied to be sorted.
    known.sort(
      proc(a, b: int32): int =
        cmp(r[].nameAt(ni, a)[], r[].nameAt(ni, b)[])
    )
    i = 0
    while i < known.len:
      let name = r[].nameAt(ni, known[i])
      spendBy(r, 1 + name[].len)
      if r.names.len == 0 or r.names[^1] != name[]:
        growing(r, r.names)
        discard r[].idOf(name[])
      inc i
    known = @[]
    # Each name's versions with their precedence, sorted once all are listed.
    var parsed = newSeq[seq[SemVer]](r.names.len)
    i = 0
    while i < ni:
      spendBy(
        r, 1 + r.installed[i].identity.package.len + r.installed[i].identity.version.len
      )
      let k = r.installed[i].identity.key
      doAssert k notin r.installedAt,
        "an installed state holds " & $r.installed[i].identity & " once"
      let v = parseSemVer(k[1])
      if v.isOk:
        let x = r[].idOf(k[0])
        growing(r, r.versions[x])
        r.versions[x].add(k[1])
        parsed[x].add(v.get)
        r.installedAt[k] = i
      inc i
    # [IMPL-DECISION G455] A version is listed with its identity's first
    # record, which needs no set: an identity listed before has a group or an
    # installed record. A record that repeats one is dropped when its group is
    # sorted. An encoding of each record was one more pass over the catalog.
    var groups: seq[(string, string)] ## identities with two records or more
    i = 0
    while i < r.catalog.len:
      spendBy(
        r, 1 + r.catalog[i].identity.package.len + r.catalog[i].identity.version.len
      )
      let k = r.catalog[i].identity.key
      let v = parseSemVer(k[1])
      inc i
      if v.isErr:
        continue
      var first = false
      r.entries.withValue(k, g):
        g[].add(i - 1)
        if g[].len == 2:
          groups.add(k)
      do:
        first = true
      if first:
        r.entries[k] = @[i - 1]
        if k notin r.installedAt:
          let x = r[].idOf(k[0])
          growing(r, r.versions[x])
          r.versions[x].add(k[1])
          parsed[x].add(v.get)
    while groups.len > 0:
      let k = groups[^1]
      var g = r.entries.getOrDefault(k)
      var keyed = newSeqOfCap[(seq[byte], int)](g.len)
      var m = 0
      while m < g.len:
        let e = r.catalog[g[m]].source.encoded
        spendBy(r, 1 + e.len)
        keyed.add((e, g[m]))
        inc m
      # Stable: of records that repeat, the first is kept, as when a set
      # dropped the later ones.
      keyed.sort(
        proc(a, b: (seq[byte], int)): int =
          cmpBytes(a[0], b[0])
      )
      g.setLen(0)
      m = 0
      while m < keyed.len:
        if m == 0 or keyed[m][0] != keyed[m - 1][0]:
          g.add(keyed[m][1])
        inc m
      r.entries[k] = move g
      groups.setLen(groups.len - 1)
    var x = 0
    while x < r.versions.len:
      let n = r.versions[x].len
      if n > 1:
        var ordered = true
        var t = 1
        while t < n and ordered:
          tick(r)
          ordered = cmp(parsed[x][t - 1], parsed[x][t]) >= 0
          inc t
        if not ordered:
          spendBy(r, n)
          # The precedence of each is read from its pair, not looked up for
          # each comparison: the lookups and their copies took 0.2 s for one
          # name's 65,536 versions. Stable, as before. A catalog in use is in
          # canonical order (G401), so its versions need no sort.
          var keyed = newSeqOfCap[(SemVer, string)](n)
          for j in 0 ..< n:
            keyed.add((move parsed[x][j], move r.versions[x][j]))
          keyed.sort(
            proc(a, b: (SemVer, string)): int =
              cmp(b[0], a[0])
          )
          for j in 0 ..< n:
            parsed[x][j] = move keyed[j][0]
            r.versions[x][j] = move keyed[j][1]
      # Freed a few at a time: a version is three strings, and one name's
      # 65,536 took 10 ms to free at once.
      while parsed[x].len > 0:
        tick(r)
        parsed[x].setLen(parsed[x].len - 1)
      inc x

  body

proc bindSteps(r: ref Resolver, x: NameId): RunSteps =
  ## Binds `r.cands[x]`, which the caller put there, and records its
  ## requirements. `r.bindOk` is false when the partial closure is then
  ## rejected: a bound package does not satisfy a new requirement (one version
  ## per name, a pin, a contract), or an edge closes a cycle. Its edges, depths
  ## and the depth limit are `settleSteps`', after both checks pass.
  ##
  ## [IMPL-DECISION G455] Each loop goes by index over lists that nothing
  ## writes while it runs (rule I2), and suspends where its turn is spent.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    r.bindOk = false
    # [IMPL-DECISION G454; Fable F1] Its depth, from its bound parents, before
    # its own edges exist: 0 for the root, else one more than the deepest.
    var d = 0'i32
    if x != r.root:
      var i = 0
      while i < r.parents[x].len:
        tick(r)
        d = max(d, r.depth[r.parents[x][i]] + 1)
        inc i
    block:
      # [G455] Numbering its dependency names is reading its dependency entries.
      var i = 0
      while i < r.cands[x].depNames.len:
        tick(r)
        var n = r.ids.getOrDefault(r.cands[x].depNames[i], -1)
        if n < 0:
          # [IMPL-DECISION G455] A name first numbered here costs what the
          # setup's numbering does: its bytes, and the growth of the lists
          # kept for each name. Counted as one unit, the 80,000 new names of
          # a maximum-size manifest made turns of 10 ms. A copy: numbering it
          # grows `cands`, which holds this one.
          let name = r.cands[x].depNames[i]
          spendBy(r, name.len)
          growing(r, r.names)
          n = r[].newId(name)
        growing(r, r.cands[x].depIds)
        r.cands[x].depIds.add(n)
        inc i
    r.depth[x] = d
    r.bound[x] = true
    inc r.boundCount
    r.maxNames = max(r.maxNames, r.boundCount)
    r.binds.add(Bind(id: x, trail: r.trail.len))
    block:
      var i = 0
      while i < r.cands[x].depIds.len:
        tick(r)
        let n = r.cands[x].depIds[i]
        if r.reqs[n].len == 0:
          r[].push(n)
        growing(r, r.reqs[n])
        growing(r, r.parents[n])
        # [IMPL-DECISION G455] (5-3c-3) A copy of the requirement: its contracts
        # are a span, and its version text a unit for each 64 bytes copied.
        spendBy(r, r.cands[x].deps[i].version.len shr 6)
        r.reqs[n].add(r.cands[x].deps[i])
        r.parents[n].add(x)
        inc i
    block:
      var i = 0
      while i < r.cands[x].depIds.len:
        tick(r)
        let n = r.cands[x].depIds[i]
        if r.bound[n]:
          if not r.cands[n].meetsVersionAndPin(r.cands[x].deps[i]):
            return
          # [SPEC PM §11 l.1215] [IMPL-DECISION G455] (5-3c-3) Each contract
          # the entry lists, looked up in what `n` provides, its probes spent.
          let q = r.cands[x].deps[i].contracts
          var j = 0
          while j < q.len:
            let (found, probes) =
              r[].lookup(r.cands[n].provides, r.lists[q.list].list[q.at + j])
            spendBy(r, probes)
            if not found:
              return
            inc j
        inc i
    # Both checks only reject, so their order does not change the answer.
    # [IMPL-DECISION G454] The cycle walk: whether a bound dependency reaches a
    # bound name that requires `x`. Depths rise strictly along bound edges and
    # `x`'s exceeds every parent's, so a name at its depth or deeper cannot lead
    # to a parent: the walk skips it.
    inc r.epoch
    let e = r.epoch
    block:
      var i = 0
      while i < r.parents[x].len:
        tick(r)
        r.parentAt[r.parents[x][i]] = e
        inc i
    r.walk.setLen(0)
    for n in r.cands[x].depIds:
      if n == x:
        return # itself
      if r.bound[n] and r.depth[n] < d and r.seenAt[n] != e:
        r.seenAt[n] = e
        r.walk.add(n)
    while r.walk.len > 0:
      let s = r.walk.pop()
      if r.parentAt[s] == e:
        return
      var i = 0
      while i < r.kids[s].len:
        tick(r)
        let k = r.kids[s][i]
        inc i
        if r.depth[k] < d and r.seenAt[k] != e:
          r.seenAt[k] = e
          r.walk.add(k)
    r.bindOk = true

  body

proc raiseTo(r: var Resolver, k: NameId, v: int32, e: uint32) =
  ## Deepens `k` to `v` if that is deeper. Its first change in this bind goes
  ## on the trail and queues it by its depth before the bind.
  if v <= r.depth[k]:
    return
  if r.changedAt[k] != e:
    r.changedAt[k] = e
    let old = r.depth[k]
    r.trail.add((k, old))
    if old >= r.buckets.len:
      r.buckets.setLen(old + 1)
    r.buckets[old].add(k)
    r.bucketLo = min(r.bucketLo, int(old))
    r.bucketHi = max(r.bucketHi, int(old))
  r.depth[k] = v

proc settleSteps(r: ref Resolver): RunSteps =
  ## [SPEC PM §11 l.1257-1260, l.1276-1277] After a bind that passed both
  ## checks: its edges join the bound graph and every name it deepens is
  ## deepened, then the depth limit is checked. A name over the limit
  ## terminates the root operation (`r.settled`); it is not backtracked.
  ##
  ## [IMPL-DECISION G454] Only what the bind changed is visited. Every edge
  ## between names bound before it goes from a lower depth to a higher one, so
  ## taking the deepened names in the order of their depths before the bind
  ## deepens each once, after all its deepened parents.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    r.settled = Opt.none(PackageError)
    let x = r.binds[^1].id
    r.binds[^1].linked = true
    let start = r.binds[^1].trail
    block:
      var i = 0
      while i < r.cands[x].depIds.len:
        tick(r)
        let n = r.cands[x].depIds[i]
        if r.bound[n]:
          growing(r, r.kids[x])
          r.kids[x].add(n)
        inc i
    block:
      var i = 0
      while i < r.parents[x].len:
        tick(r)
        growing(r, r.kids[r.parents[x][i]])
        r.kids[r.parents[x][i]].add(x)
        inc i
    inc r.epoch
    let e = r.epoch
    r.changedAt[x] = e
    let dx = r.depth[x]
    r.bucketLo = r.buckets.len
    r.bucketHi = -1
    block:
      var i = 0
      while i < r.kids[x].len:
        tick(r)
        r[].raiseTo(r.kids[x][i], dx + 1, e)
        inc i
    var b = r.bucketLo
    while b <= r.bucketHi:
      var i = 0
      while i < r.buckets[b].len:
        # Each is queued in a strictly later bucket than the name deepening it.
        let n = r.buckets[b][i]
        inc i
        let dn = r.depth[n]
        var j = 0
        while j < r.kids[n].len:
          tick(r)
          r[].raiseTo(r.kids[n][j], dn + 1, e)
          inc j
      r.buckets[b].setLen(0)
      inc b
    # The greatest depth of a bound name: an unchanged one is no deeper than
    # before, and `maxDepth` already covers it. It is raised before the limit
    # check reports, as for every bound name.
    r.maxDepth = max(r.maxDepth, int(dx))
    for i in start ..< r.trail.len:
      r.maxDepth = max(r.maxDepth, int(r.depth[r.trail[i][0]]))
    # Before the bind no name was over the limit, or the run would have ended.
    # So a name over it now is a changed bound name or a name a changed bound
    # name at the limit or deeper requires.
    let limit = r.limits.depth
    var over = -1'i32
    var i = start - 1
    while i < r.trail.len:
      let n =
        if i < start:
          x
        else:
          r.trail[i][0]
      inc i
      if int(r.depth[n]) > limit and (over < 0 or r[].before(n, over)):
        over = n
      if int(r.depth[n]) >= limit:
        # [IMPL-DECISION G455] Reading a name's dependency entries, counted.
        var j = 0
        while j < r.cands[n].depIds.len:
          tick(r)
          let m = r.cands[n].depIds[j]
          inc j
          if over < 0 or r[].before(m, over):
            over = m
    if over >= 0:
      # [ruling S1] No depth in the message: it would show the limit, which is
      # protected policy input (PM l.1514), to the caller.
      r.tripped = "dependency_depth"
      r.settled = Opt.some(
        unavailableDependency(r.names[over] & " is beyond the dependency-depth limit")
      )

  body

proc unbindSteps(r: ref Resolver, x: NameId): RunSteps =
  ## Undoes the last bind, `x`'s: its depth changes, its edges, its
  ## requirements; `x` is unresolved again if it is still required.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    let b = r.binds.pop()
    doAssert b.id == x, "binds are undone in reverse order"
    var i = r.trail.high
    while i >= b.trail:
      tick(r)
      let (n, old) = r.trail[i]
      r.depth[n] = old
      dec i
    r.trail.setLen(b.trail)
    if b.linked:
      var j = 0
      while j < r.parents[x].len:
        tick(r)
        let p = r.parents[x][j]
        inc j
        doAssert r.kids[p][^1] == x, "a bind's edges are the last of its parents'"
        r.kids[p].setLen(r.kids[p].len - 1)
      r.kids[x].setLen(0)
    var k = r.cands[x].depIds.high
    while k >= 0:
      tick(r)
      let n = r.cands[x].depIds[k]
      dec k
      doAssert r.parents[n][^1] == x,
        "a bind's requirements are the last of each name's"
      r.parents[n].setLen(r.parents[n].len - 1)
      r.reqs[n].setLen(r.reqs[n].len - 1)
    r.bound[x] = false
    dec r.boundCount
    r.cands[x] = Cand()
    if r.reqs[x].len > 0:
      r[].push(x)

  body

proc unboundDepth(r: var Resolver, x: NameId): int =
  ## [SPEC PM §11 l.1256] A required name's depth before it is bound: one more
  ## than its deepest bound parent's. Every bound name is reachable from the
  ## root, so this is the greatest number of edges on a path to it.
  for p in r.parents[x]:
    inc r.work
    result = max(result, int(r.depth[p]) + 1)

proc versionSteps(r: ref Resolver, f: int): RunSteps =
  ## [SPEC PM §11] The next version of frame `f` satisfying every accumulated
  ## requirement, in descending SemVer precedence (`r.version`; none when it
  ## has no more). [IMPL-DECISION G454] Tested as it comes: the name's
  ## requirements are the same each time its frame tries a version, so this is
  ## the sequence a list made at the frame's push would give.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    r.version = Opt.none(string)
    let x = r.stack[f].id
    while r.stack[f].next < r.versions[x].len:
      let v = r.versions[x][r.stack[f].next]
      inc r.stack[f].next
      var ok = true
      var i = 0
      while i < r.reqs[x].len:
        tick(r)
        if not satisfies(r.reqs[x][i].kind, r.reqs[x][i].version, v):
          ok = false
          break
        inc i
      if ok:
        r.version = Opt.some(v)
        return

  body

proc charge(r: var Resolver, name, version: string): Result[void, PackageError] =
  ## [SPEC PM §11 l.1262-1268] [IMPL-DECISION I110] One charge per package name
  ## and version in one root operation, whatever its records are and whatever
  ## the examination finds, including when it is examined again after
  ## backtracking (B3, the TF-59 interim). The limit is checked first, so
  ## nothing past it is examined.
  if (name, version) in r.charged:
    return ok()
  let n = r.considered.getOrDefault(name)
  if n >= r.limits.candidates:
    r.tripped = "candidates_per_name"
    return err(
      unavailableDependency(
        "resolution needs another candidate for " & name &
          " beyond the candidates-per-name limit"
      )
    )
  r.considered[name] = n + 1
  r.charged.incl((name, version))
  ok()

proc attempt(r: var Resolver): Result[void, PackageError] =
  ## [SPEC PM §11] Every tentative binding counts, and the count never
  ## decreases.
  if r.attempts >= r.limits.attempts:
    r.tripped = "assignment_attempts"
    return
      err(unavailableDependency("resolution exhausted the assignment-attempt limit"))
  inc r.attempts
  ok()

func newerThan(v, current: string): bool =
  let a = parseSemVer(v)
  let b = parseSemVer(current)
  a.isOk and b.isOk and cmp(a.get, b.get) > 0

proc sourceRoot(
    r: var Resolver, root: RootReference, package: Opt[string]
): Result[Cand, PackageError] =
  ## [SPEC PM §11, §15] A supplied source's verified manifest fixes the root.
  ## It has no identity until it is inspected, so it is charged after; an
  ## ineligible or unavailable source charges nothing.
  let x = ?r.inspectSource(root.source.get)
  if x.isNil:
    return err(pending())
  case x[].kind
  of ikUnavailable:
    return err(packageError(pecPackageUnavailable, "the root source: " & x[].reason))
  of ikIneligible:
    return err(x[].error)
  of ikEligible:
    discard
  if package.get(x[].identity.package) != x[].identity.package or
      root.version.get(x[].identity.version) != x[].identity.version:
    # [SPEC PM §8 l.1074-1079] a manifest that conflicts with the selected
    # package reference is an invalid package, not an invalid request
    return err(
      packageError(pecInvalidPackage, "the source's manifest declares " & $x[].identity)
    )
  let k = root.source.get.encoded
  var numbers = r.numbered.getOrDefault(k, -1)
  if numbers < 0:
    # [IMPL-DECISION G455] (5-3c-3) Its contracts are numbered once it is read
    # within the bound: it is called again after. Without any, here.
    if x[].listsNoContract:
      numbers =
        r.numberedEmpty(InternNeed(installed: -1, source: k), x[].dependencies.len)
    else:
      r.intern = Opt.some(InternNeed(installed: -1, source: k))
      return err(pending())
  ?r.charge(x[].identity.package, x[].identity.version)
  let (names, deps) = r.fresh(x[].dependencies, numbers)
  let at = r.installedAt.getOrDefault(x[].identity.key, -1)
  ok(
    Cand(
      identity: x[].identity,
      commitment: x[].commitment,
      installed: at >= 0 and r.installed[at].commitment == x[].commitment,
      source: root.source,
      depNames: names,
      deps: deps,
      provides: r.providedSpan(numbers),
    )
  )

proc versionRoot(r: var Resolver, id: PackageIdentity): Result[Cand, PackageError] =
  if not r.known(id):
    return err(packageError(pecPackageUnavailable, "no source holds " & $id))
  ?r.charge(id.package, id.version)
  let at = ?r.evaluate(id)
  var c = ?r.rootCandidate(id, r.evals[at])
  if c.isNone:
    return err(r.evals[at].firstError.get(packageError(pecPackageUnavailable, $id)))
  # [IMPL-DECISION G455] Moved, not copied: a copy of a maximum-size
  # manifest's requirement list took milliseconds of the turn.
  ok(move c.get)

proc selectRoot(r: var Resolver, root: RootReference): Result[Opt[Cand], PackageError] =
  ## [SPEC PM §11, §15] A supplied source's verified manifest fixes the root;
  ## otherwise an explicit version does; otherwise the highest eligible normal
  ## release reached in descending order. Each root record examined is
  ## charged. The root is not a backtracking point. None: an update with no
  ## applicable newer version.
  var package = root.package
  if root.newerThan.isSome:
    let current = root.newerThan.get
    if package.get(current.package) != current.package:
      return err(invalidRequest("an update names one package"))
    parseSemVer(current.version).isOkOr:
      return err(invalidRequest("current is not a package version: " & error))
    if current.key notin r.installedAt:
      # [SPEC PM §15 l.1715]
      return err(packageError(pecPackageNotInstalled, $current & " is not installed"))
    package = Opt.some(current.package)
  if package.isNone and root.source.isNone:
    return err(invalidRequest("the root names a package, a source or both"))
  if root.version.isSome:
    if package.isNone:
      return err(invalidRequest("a root version needs a package"))
    parseSemVer(root.version.get).isOkOr:
      return err(invalidRequest("the root version is not a package version: " & error))
  if root.newerThan.isSome and root.version.isSome and
      not root.version.get.newerThan(root.newerThan.get.version):
    # [SPEC PM §15 l.1704]
    return err(invalidRequest("the target version is not newer than current"))
  if root.source.isSome:
    let c = ?r.sourceRoot(root, package)
    if root.newerThan.isSome and
        not c.identity.version.newerThan(root.newerThan.get.version):
      return err(invalidRequest("the source's version is not newer than current"))
    return ok(Opt.some(c))
  let name = package.get
  if root.version.isSome:
    return ok(
      Opt.some(
        ?r.versionRoot(PackageIdentity(package: name, version: root.version.get))
      )
    )
  var first = Opt.none(PackageError)
  for v in r.versions[r.idOf(name)]:
    if parseSemVer(v).get.isPrerelease:
      continue # [SPEC PM §11] selected only by an explicit version or a source
    if root.newerThan.isSome and not v.newerThan(root.newerThan.get.version):
      break # descending: no newer version is left
    let id = PackageIdentity(package: name, version: v)
    ?r.charge(name, v)
    let at = ?r.evaluate(id)
    let c = ?r.rootCandidate(id, r.evals[at])
    if c.isSome:
      return ok(c)
    if root.newerThan.isSome and r.evals[at].unsupportedOnly:
      continue # [SPEC PM §15 l.1707] not applicable
    if first.isNone:
      first = r.evals[at].firstError
  if root.newerThan.isNone:
    return err(
      first.get(packageError(pecPackageUnavailable, "no normal release of " & name))
    )
  if first.isSome:
    # [IMPL-DECISION I110] Q7, the TF-60 interim: newer versions exist and none
    # is eligible, not all for an unsupported schema.
    return err(first.get)
  let p = r.installed[r.installedAt.getOrDefault(root.newerThan.get.key)]
  if not r.trust.accepts(p.signer, p.identity.package):
    # [IMPL-DECISION G166] TF-07's update half: an update that would change
    # nothing fails while the retained signer is not accepted.
    return err(
      packageError(
        pecSignature,
        "the retained signer of the installed " & $p.identity &
          " is not an accepted signer authorized for " & p.identity.package,
      )
    )
  ok(Opt.none(Cand))

func counters(r: Resolver): ResolverCounters =
  var names: seq[string]
  for n in r.considered.keys:
    names.add(n)
  names.sort()
  for n in names:
    result.considered.add((n, r.considered.getOrDefault(n)))
  result.names = r.maxNames
  result.depth = r.maxDepth
  result.attempts = r.attempts
  result.limit = r.tripped
  result.entries = r.inputsRead
  result.bound = r.stopped

proc closureSteps(r: ref Resolver): RunSteps =
  ## The complete closure (`r.resolution`), in package-name byte order.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    var picked: seq[(string, NameId)]
    var i = 0
    while i < r.names.len:
      if r.bound[i]:
        tick(r)
        picked.add((r.names[i], NameId(i)))
      inc i
    picked.sort()
    r.resolution = Resolution(root: r.cands[r.root].identity)
    var j = 0
    while j < picked.len:
      let x = picked[j][1]
      inc j
      # [IMPL] Fields are read in place: a `let` copy of a candidate copies its
      # dependency lists, which made this loop cubic in a dense closure.
      var p = SelectedPackage(
        identity: r.cands[x].identity,
        commitment: r.cands[x].commitment,
        installed: r.cands[x].installed,
        source:
          if r.cands[x].installed and x != r.root:
            Opt.none(PackageSource)
          else:
            # [SPEC PM §15 l.1686-1687] The root's selected or supplied source is
            # kept even when it is installed: its signature is the request's.
            r.cands[x].source,
        depth: int(r.depth[x]),
      )
      if r.cands[x].edges.isSome:
        p.resolvedDependencies = r.cands[x].edges.get
      else:
        p.resolvedDependencies = newSeqOfCap[ResolvedDependency](r.cands[x].depIds.len)
        var k = 0
        while k < r.cands[x].depIds.len:
          tick(r)
          let d = r.cands[x].depIds[k]
          inc k
          p.resolvedDependencies.add(
            ResolvedDependency(
              identity: r.cands[d].identity, commitment: r.cands[d].commitment
            )
          )
      r.resolution.packages.add(move p)
    r.resolution.counters = r[].counters

  body

template finish(r: ref Resolver, o: Result[Resolution, PackageError]) =
  ## [IMPL-DECISION G455] The run's outcome: marked, yielded, and the run ends
  ## (rule I5). Only in `runSteps`' body.
  r.ended = true
  yield Suspension(kind: suDone, outcome: o)
  return

template fail(r: ref Resolver, e: PackageError) =
  finish(r, Result[Resolution, PackageError].err(e))

template sub(r: ref Resolver, steps: RunSteps) =
  ## [IMPL-DECISION G455] A nested run of steps: each suspension it yields is
  ## the run's. Nested steps only spend turns; their answers are marks in `r`.
  let nested = steps
  for s in nested():
    yield s

when defined(lcnTestHooks):
  var contractHashShiftForTests* {.threadvar.}: int
    ## Test hook (D27; DECISIONS I89) [IMPL-DECISION G455] (5-3c-3): when not 0, each
    ## contract's hash is shifted left by it, so that every encoding's first slot is the same
    ## and all of them probe one chain, as encodings chosen to collide would. Inert at 0; set
    ## by a suite on its own thread.

proc contractHash(enc: openArray[byte]): Hash {.inline.} =
  ## [IMPL-DECISION G455] (5-3c-3) An encoding's hash: std/hashes', unkeyed, so the same
  ## inputs give the same probes, work and turns in every run (Fable's review of 5-3c-3 §1).
  ## Its keys are chosen by a signer; a chain of collisions costs probes, each a unit and a
  ## turn check, never a step of its own. [IMPL-DECISION G482] The same function over the
  ## same bytes whether they are a range of a record's encodings or a `seq` of their own
  ## (std/hashes has one `hash` for both, and a test holds them equal), so every probe, and
  ## the work, is what it was.
  result = hash(enc)
  when defined(lcnTestHooks):
    {.cast(gcsafe).}:
      if contractHashShiftForTests != 0:
        result = result shl contractHashShiftForTests

func sameBytes(a: seq[byte], b: openArray[byte]): bool {.inline.} =
  a.len == b.len and (a.len == 0 or equalMem(unsafeAddr a[0], unsafeAddr b[0], a.len))

template probeSteps(
    r: ref Resolver, old: bool, h: Hash, enc: untyped, found: var int32
) =
  ## [IMPL-DECISION G455] (5-3c-3) The number of the contract encoded as `enc` in the slots
  ## (`old`: the slots before their last growth), or -1. Each probe is a unit and a turn
  ## check, so a chain of colliding hashes suspends where the turn is spent. Only inside a
  ## run's iterator; nothing else changes the table while it is suspended.
  found = -1
  block probing:
    let count = if old: r.oldCount else: r.slotCount
    if count == 0:
      break probing
    let m = count - 1
    var i = h and m
    while true:
      tick(r)
      let n =
        if old:
          slotAt(r.oldSlots, i) - 1
        else:
          slotAt(r.slots, i) - 1
      if n < 0:
        break probing
      if r.hashes.at(n) == h and sameBytes(r.encodings.at(n), enc):
        found = n
        break probing
      i = (i + 1) and m

template placeSteps(r: ref Resolver, h: Hash, n: int32) =
  ## [IMPL-DECISION G455] (5-3c-3) Puts number `n` in the first free slot from its hash's.
  ## Each probe is a unit and a turn check, and a block's allocation its zeroing, a cache
  ## line a unit.
  block placing:
    let m = r.slotCount - 1
    var i = h and m
    while true:
      tick(r)
      let b = i shr BlockBits
      if r.slots[b].len == 0:
        r.slots[b] = newSeq[int32](min(r.slotCount, BlockLen))
        spendBy(r, min(r.slotCount, BlockLen) div 16)
      if r.slots[b][i and BlockMask] == 0:
        r.slots[b][i and BlockMask] = n + 1
        break placing
      i = (i + 1) and m

template numberSteps(r: ref Resolver, enc: untyped, keep: untyped, num: var int32) =
  ## [IMPL-DECISION G455] (5-3c-3) The number of the contract encoded as `enc`, numbered now
  ## if it is new (`keep`, the encoding as a `seq`, is then put in the table: an installed
  ## record's encoding moved, or [G482] a copy of a range of a catalog record's encodings,
  ## the one allocation the encode made before). Each probe and each number moved is
  ## a unit and a turn check: the work is the steps walked (Fable's review of 5-3c-3 §1).
  ## Nothing it does is a step of the table's size:
  ## - the lists by number are `Blocks`, which grow without copying;
  ## - the slots double when the numbers would fill half of them, as a list of unallocated
  ##   blocks; and the numbers then move into the new slots two for each new number, so the
  ##   old ones are empty before the new ones fill half. Until then a number is looked for
  ##   in both.
  block numbering:
    let h = contractHash(enc)
    probeSteps(r, false, h, enc, num)
    if num < 0 and r.oldCount > 0:
      probeSteps(r, true, h, enc, num)
    if num >= 0:
      break numbering
    if (r.encodings.len + 1) * 2 > r.slotCount:
      doAssert r.oldCount == 0,
        "the numbers have moved out of the old slots before the slots grow again"
      r.oldSlots = move r.slots
      r.oldCount = r.slotCount
      r.moved = 0
      r.slotCount = max(FirstContractSlots, 2 * r.slotCount)
      r.slots = newSeq[seq[int32]](max(1, r.slotCount shr BlockBits))
      spendBy(r, 1 + r.slots.len shr 2) # the blocks' list, zeroed
    num = int32(r.encodings.len)
    r.encodings.add(keep)
    r.hashes.add(h)
    r.marks.add(0'u32)
    placeSteps(r, h, num)
    if r.oldCount > 0:
      let before = r.oldCount div 2 # the numbers the old slots held
      var k = 0
      while k < 2 and r.moved < before:
        placeSteps(r, r.hashes.at(r.moved), int32(r.moved))
        inc r.moved
        inc k
      if r.moved >= before:
        spendBy(r, r.oldSlots.len) # its blocks, freed
        r.oldSlots = @[]
        r.oldCount = 0

proc internSteps(r: ref Resolver): RunSteps =
  ## [IMPL-DECISION G455] (5-3c-3) Numbers the contracts of the record
  ## `r.intern` names, read within the operation bound (G477): each dependency
  ## entry's as it lists them, then the record's provided ones, once each and
  ## ascending. A contract costs a unit and its encoded bytes (an overcount is
  ## safe; Fable's review of the contract turns), its probes and its marks; an
  ## entry or a module a unit. [IMPL-DECISION G482] A catalog record's encodings
  ## leave its inspection when the walk starts (Fable's condition 1: no view of
  ## the table is held across a turn check), and go when it ends: nothing in the
  ## run reads them again.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    let need = r.intern.get
    r.intern = Opt.none(InternNeed)
    var nums: Numbers
    var walk = ContractBytes()
      ## a catalog record's encodings, taken from its inspection. The initializer is
      ## I92's rule (`tools/lint/firstwrite.py`): its first write is in a branch.
    block:
      # Sized once, so neither list grows: its contracts and its entries,
      # counted by its entries and modules.
      var contracts, entries, modules = 0
      if need.installed >= 0:
        template p(): untyped =
          r.installed[need.installed]

        entries = p.dependencies.len
        modules = p.modules.len
        for d in p.dependencies:
          contracts += d.contracts.len
        for m in p.modules:
          contracts += int(m.primaryContract.isSome) + m.implements.len + m.extends.len
      else:
        r.inspected.withValue(need.source, v):
          entries = v.dependencies.len
          contracts = v.contracts.ends.len
          walk = move v.contracts
      spendBy(r, 1 + entries + modules)
      nums.list = newSeqOfCap[int32](contracts)
      nums.entryAt = newSeqOfCap[int32](entries + 1)
    var cur: Cursor
    while true:
      var enc: seq[byte]
      var at: Slice[int]
      var steps: int
      let step = r[].nextContract(need, walk, cur, nums, enc, at, steps)
      spendBy(r, steps - 1) # the entry steps before this one
      case step
      of csDone:
        break
      of csEntry:
        tick(r)
      of csContract:
        var num: int32
        if need.installed >= 0:
          spendBy(r, 1 + enc.len)
          numberSteps(r, enc, move enc, num)
        else:
          spendBy(r, 1 + at.len)
          numberSteps(
            r,
            walk.bytes.toOpenArrayByte(at.a, at.b),
            @(walk.bytes.toOpenArrayByte(at.a, at.b)),
            num,
          )
        nums.list.add(num)
    walk = ContractBytes() # its two blocks, freed: no unit
    # Its provided contracts once each, then ascending: in order already
    # unless an earlier record numbered some of them.
    let start = int(nums.entryAt[^1])
    inc r.markEpoch
    let e = r.markEpoch
    var w = start
    var k = start
    while k < nums.list.len:
      tick(r)
      let n = nums.list[k]
      if r.marks.at(n) != e:
        r.marks.at(n) = e
        nums.list[w] = n
        inc w
      inc k
    nums.list.setLen(w)
    var ordered = true
    k = start + 1
    while k < w and ordered:
      tick(r)
      ordered = nums.list[k - 1] < nums.list[k]
      inc k
    if not ordered:
      # A merge sort, bottom up through a buffer, a unit for each number it
      # moves, so it suspends where its turn is spent.
      let n = w - start
      var buf = newSeq[int32](n)
      spendBy(r, 1 + n div 16) # its zeroing
      var inBuf = false # where the runs being merged are
      var width = 1
      while width < n:
        var lo = 0
        while lo < n:
          let mid = min(lo + width, n)
          let hi = min(lo + 2 * width, n)
          var a = lo
          var b = mid
          var o = lo
          while o < hi:
            tick(r)
            template src(i: int): int32 =
              (if inBuf: buf[i] else: nums.list[start + i])

            let takeA = b >= hi or (a < mid and src(a) <= src(b))
            let v =
              if takeA:
                src(a)
              else:
                src(b)
            if takeA:
              inc a
            else:
              inc b
            if inBuf:
              nums.list[start + o] = v
            else:
              buf[o] = v
            inc o
          lo = hi
        inBuf = not inBuf
        width *= 2
      if inBuf:
        var k = 0
        while k < n:
          tick(r)
          nums.list[start + k] = buf[k]
          inc k
      buf = @[]
    let at = int32(r.lists.len)
    growing(r, r.lists)
    r.lists.add(move nums)
    if need.installed >= 0:
      r.installedNumbers[need.installed] = at + 1
    else:
      r.numbered[need.source] = at

  body

proc needSteps(r: ref Resolver, f: int): RunSteps =
  ## [SPEC PM §11 l.1213-1215, l.1304] [IMPL-DECISION G455] (5-3c-3) What frame
  ## `f`'s requirements ask of every candidate: the contracts they list, once
  ## each, and the commitments they pin, as the first and whether another
  ## differs. Gathered once, when the frame is pushed: its requirements do not
  ## change while it is on the stack (G454). A unit for each requirement and
  ## each contract listed.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    let x = r.stack[f].id
    block:
      # Sized once, for every contract listed, so it does not grow.
      var listed = 0
      var i = 0
      while i < r.reqs[x].len:
        tick(r)
        listed += r.reqs[x][i].contracts.len
        inc i
      r.stack[f].need = newSeqOfCap[int32](listed)
    inc r.markEpoch
    let e = r.markEpoch
    var i = 0
    while i < r.reqs[x].len:
      tick(r)
      if r.reqs[x][i].pin.isSome:
        if r.stack[f].pin.isNone:
          r.stack[f].pin = r.reqs[x][i].pin
        elif r.stack[f].pin.get != r.reqs[x][i].pin.get:
          r.stack[f].pinConflict = true
      let q = r.reqs[x][i].contracts
      var j = 0
      while j < q.len:
        tick(r)
        let n = r.lists[q.list].list[q.at + j]
        if r.marks.at(n) != e:
          r.marks.at(n) = e
          r.stack[f].need.add(n)
        inc j
      inc i

  body

proc allowSteps(r: ref Resolver, f: int, at: int): RunSteps =
  ## [SPEC PM §11 l.1213-1215, l.1304] [IMPL-DECISION G455] (5-3c-3) Which
  ## catalog records of evaluation `at` frame `f`'s pins allow and provide
  ## every contract its requirements list (`r.allowed`), and whether the
  ## installed record, eligible and allowed, provides them
  ## (`r.installedCovers`). [IMPL-DECISION I110] Pins apply per record (Q8): a
  ## pinned version the catalog lists under another commitment is not a
  ## candidate. Each contract is looked up by binary search, its probes spent.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    r.allowed.setLen(0)
    r.installedCovers = false
    var i = 0
    while i < r.evals[at].picks.len:
      tick(r)
      if r.stack[f].allows(r.evals[at].picks[i].commitment):
        var covers = true
        var j = 0
        while covers and j < r.stack[f].need.len:
          let (found, probes) =
            r[].lookup(r.evals[at].picks[i].provides, r.stack[f].need[j])
          spendBy(r, probes)
          covers = found
          inc j
        if covers:
          r.allowed.add(i)
      inc i
    let k = r.evals[at].installed
    if k >= 0 and r.evals[at].installedError.isNone and
        r.stack[f].allows(r.installed[k].commitment):
      let span = r[].providedSpan(r.installedNumbers[k] - 1)
      var covers = true
      var j = 0
      while covers and j < r.stack[f].need.len:
        let (found, probes) = r[].lookup(span, r.stack[f].need[j])
        spendBy(r, probes)
        covers = found
        inc j
      r.installedCovers = covers

  body

proc allowPinned(r: var Resolver, f: int, at: int) =
  ## [IMPL-DECISION G455] (5-3c-3) `allowSteps` for a frame whose requirements
  ## list no contract: which records the pins allow, in place, a unit for each
  ## (`allowSteps`' count). The next check ends the turn.
  r.allowed.setLen(0)
  r.work += int64(r.evals[at].picks.len)
  for i in 0 ..< r.evals[at].picks.len:
    if r.stack[f].allows(r.evals[at].picks[i].commitment):
      r.allowed.add(i)
  let k = r.evals[at].installed
  r.installedCovers =
    k >= 0 and r.evals[at].installedError.isNone and
    r.stack[f].allows(r.installed[k].commitment)

proc runSteps(r: ref Resolver, root: RootReference): RunSteps =
  ## [SPEC PM §11, §15] [IMPL-DECISION G455] The search, as a run that
  ## suspends where it needs an inspection or a retained-bytes answer and
  ## where its turn's work is spent (5-3c's plan §3.5). `selectRoot` and
  ## `evaluate` are called again once what they need is supplied: their
  ## charges are once per name and version, and their memos are filled only
  ## by supplied answers and completed evaluations, so a second call sees what
  ## a synchronous run would.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    sub(r, setupSteps(r))
    var picked = Opt.none(Cand)
    while true:
      var got = r[].selectRoot(root)
      if r.miss.isSome:
        yield r[].takeMiss()
        continue
      if r.intern.isSome:
        sub(r, internSteps(r))
        continue
      if got.isErr:
        fail(r, got.error)
      picked = move(got.get)
      break
    if picked.isNone:
      finish(
        r,
        Result[Resolution, PackageError].ok(
          Resolution(root: root.newerThan.get, unchanged: true, counters: r[].counters)
        ),
      )
    # [IMPL-DECISION G455] Building a candidate's requirement list, counted by
    # its entries: one of a maximum-size manifest, about 80,000, is built in one
    # go, and the bind that reads it then starts a turn of its own.
    spendBy(r, picked.get.deps.len)
    r.root = r[].idOf(picked.get.identity.package)
    # [SPEC PM §11] The root counts toward the partial closure, at depth zero;
    # it was charged when it was examined, and binding it is an attempt.
    block:
      let a = r[].attempt()
      if a.isErr:
        fail(r, a.error)
    r.cands[r.root] = move(picked.get)
    picked = Opt.none(Cand)
    sub(r, bindSteps(r, r.root))
    if not r.bindOk:
      fail(r, unavailableDependency("the root's own dependencies close a cycle"))
    sub(r, settleSteps(r))
    if r.settled.isSome:
      fail(r, r.settled.get)

    while true:
      # [SPEC PM §11] The unresolved package name first in UTF-8 byte order: the
      # heap's top once the entries that are no longer unresolved are dropped.
      var next = -1'i32
      while r.unresolved.len > 0:
        let top = r.unresolved[0]
        if r.reqs[top].len > 0 and not r.bound[top]:
          next = top
          break
        r[].popTop()
        turnCheck(r)
      if next < 0:
        sub(r, closureSteps(r))
        finish(r, Result[Resolution, PackageError].ok(move r.resolution))
      r.stack.add(Frame(id: next, depth: -1))
      sub(r, needSteps(r, r.stack.high))
      var placed = false
      while r.stack.len > 0 and not placed:
        let f = r.stack.len - 1
        if r.stack[f].bound:
          sub(r, unbindSteps(r, r.stack[f].id))
          r.stack[f].bound = false
        while true:
          let x = r.stack[f].id
          sub(r, versionSteps(r, f))
          if r.version.isNone:
            break
          let version = r.version.get
          if r.stack[f].depth < 0:
            r.stack[f].depth = r[].unboundDepth(x)
          if r.stack[f].depth > r.limits.depth:
            r.tripped = "dependency_depth" # [ruling S1] no depth in the message
            fail(
              r,
              unavailableDependency(
                "inspecting " & r.names[x] & " exceeds the dependency-depth limit"
              ),
            )
          let name = r.names[x]
          let id = PackageIdentity(package: name, version: version)
          if (name, version) notin r.charged and r[].excludedByKnownCommitment(id, f):
            continue
          block:
            let ch = r[].charge(name, version)
            if ch.isErr:
              fail(r, ch.error)
          var at = -1
          while true:
            let got = r[].evaluate(id)
            if r.miss.isSome:
              yield r[].takeMiss()
              continue
            if r.intern.isSome:
              sub(r, internSteps(r))
              continue
            if got.isErr:
              fail(r, got.error)
            at = got.get
            break
          if r.stack[f].need.len == 0:
            r[].allowPinned(f, at)
          else:
            sub(r, allowSteps(r, f, at))
          var dc = r[].dependencyCandidate(f, id, r.evals[at])
          if dc.isErr:
            fail(r, dc.error)
          if dc.get.isNone:
            continue
          spendBy(r, dc.get.get.deps.len) # as the root's
          if r.boundCount + 1 > r.limits.names:
            r.tripped = "partial_closure_names"
            fail(
              r,
              unavailableDependency(
                "adding " & name & " exceeds the partial-closure package-name limit"
              ),
            )
          block:
            let a = r[].attempt()
            if a.isErr:
              fail(r, a.error)
          r.cands[x] = move(dc.get.get)
          sub(r, bindSteps(r, x))
          if r.bindOk:
            sub(r, settleSteps(r))
            if r.settled.isSome:
              fail(r, r.settled.get)
            r.stack[f].bound = true
            placed = true
            break
          sub(r, unbindSteps(r, x))
        if not placed:
          tick(r) # its need is a list of numbers: freed in one go, walking none
          discard r.stack.pop()
      if not placed:
        fail(r, unavailableDependency("no complete dependency closure exists"))

  body

proc releaseSteps(r: ref Resolver): RunSteps =
  ## [IMPL-DECISION G455] Frees what a run holds, a turn's work at a time, the
  ## work being the elements freed: at the maxima a run holds gigabytes, and
  ## freeing them at once would hold the module thread for seconds. Yields
  ## `suDone` (with no outcome that matters) once all is freed. A table is
  ## freed in one go, counted as its size: only `inspected` holds much, and its
  ## values are freed one by one first.
  iterator body(): Suspension {.closure, gcsafe, raises: [].} =
    while r.names.len > 0:
      let n = r.names.high
      var size =
        1 + r.reqs[n].len + r.parents[n].len + r.kids[n].len + r.versions[n].len +
        r.cands[n].deps.len
      if r.cands[n].edges.isSome:
        size += r.cands[n].edges.get.len
      spendBy(r, size)
      r.ids.del(r.names[n])
      r.names.setLen(n)
      r.versions.setLen(n)
      r.reqs.setLen(n)
      r.parents.setLen(n)
      r.kids.setLen(n)
      r.depth.setLen(n)
      r.cands.setLen(n)
      r.bound.setLen(n)
      r.seenAt.setLen(n)
      r.parentAt.setLen(n)
      r.changedAt.setLen(n)
    while r.evals.len > 0:
      var size = 1 + r.evals[^1].errors.len
      for p in r.evals[^1].picks:
        size += 1 + p.deps.len
      spendBy(r, size)
      r.evals.setLen(r.evals.len - 1)
    # Rule I2: no view of the table is held across a yield.
    var keys = newSeqOfCap[seq[byte]](r.inspected.len)
    for k in r.inspected.keys:
      keys.add(k)
    spendBy(r, keys.len)
    while keys.len > 0:
      var size = 1
      r.inspected.withValue(keys[^1], v):
        # (5-3c-3) With the contracts its entries list: one not numbered still
        # holds them.
        size = v[].inputCount
        v[] = Inspection(kind: ikUnavailable)
      keys.setLen(keys.len - 1)
      spendBy(r, size)
    # [IMPL-DECISION G455] (5-3c-3) The numbered contracts: a record's numbers
    # and an encoding at a time, then the slots, hashes and marks, each in one
    # go (no keys).
    while r.lists.len > 0:
      spendBy(r, 2)
      r.lists.setLen(r.lists.len - 1)
    while r.encodings.len > 0:
      spendBy(r, 1)
      r.encodings.dropLast()
    spendBy(
      r,
      5 + r.numbered.len + r.hashes.blocks.len + r.marks.blocks.len + r.slots.len +
        r.oldSlots.len,
    )
    r.numbered.clear()
    r.hashes = Blocks[Hash]()
    r.marks = Blocks[uint32]()
    r.slots = @[]
    r.oldSlots = @[]
    r.slotCount = 0
    r.oldCount = 0
    r.installedNumbers = @[]
    spendBy(r, r.inspected.len + r.ids.len + r.evalAt.len + r.partial.len)
    r.inspected.clear()
    r.ids.clear()
    r.evalAt.clear()
    r.partial.clear()
    # The catalog and its index by identity, an entry at a time: 65,536 entries
    # freed at once took 8 ms.
    while r.catalog.len > 0:
      spendBy(r, 2)
      r.entries.del(r.catalog[^1].identity.key)
      r.catalog.setLen(r.catalog.len - 1)
    while r.installed.len > 0:
      spendBy(r, 2)
      r.installedAt.del(r.installed[^1].identity.key)
      r.installed.setLen(r.installed.len - 1)
    spendBy(
      r,
      r.entries.len + r.installedAt.len + r.charged.len + r.considered.len +
        r.retainedAnswers.len,
    )
    r.entries.clear()
    r.installedAt.clear()
    r.charged.clear()
    r.considered.clear()
    r.retainedAnswers.clear()
    spendBy(
      r,
      r.unresolved.len + r.binds.len + r.trail.len + r.buckets.len + r.walk.len +
        r.stack.len,
    )
    r.unresolved.setLen(0)
    r.binds.setLen(0)
    r.trail.setLen(0)
    r.buckets.setLen(0)
    r.walk.setLen(0)
    r.stack.setLen(0)
    r.resolution = Resolution()
    yield
      Suspension(kind: suDone, outcome: Result[Resolution, PackageError].err(pending()))

  body

# The resumable run --------------------------------------------------------------------

const
  ResolverTurnWork* = 32_768'i64
    ## [IMPL-DECISION G455] The work units one turn of a run spends before it
    ## yields `suTurn` (5-3c's plan §3.6): a constant, not configuration (Q5),
    ## since it changes no result, no counter and no limit (PM l.1279-1280). The
    ## bench calibrated it (docs/CONFORMANCE.md, "The resumable run"): the
    ## plan's 65,536 gave turns of 12 to 13 ms at the maxima on the Mac.
  NoTurnBudget* = high(int64) ## a run that never yields `suTurn`

type ResolverRun* = ref object
  ## [IMPL-DECISION G455] One root operation's resolution, resumable. Its
  ## driver holds it; it holds the resolver and its steps, and the resolver
  ## holds neither (rule I6).
  r: ref Resolver
  steps: RunSteps
  releasing: RunSteps ## `release`'s steps, once it is called
  budget: int64

proc startRun*(
    input: sink ResolverInput, root: RootReference, budget = ResolverTurnWork
): ResolverRun =
  ## [IMPL-DECISION G455] A run of `root`'s resolution over `input`, none of it
  ## done yet: `resume` runs it. `input.inspect` and `input.retained` are not
  ## called: each inspection and each retained-bytes answer is asked for with
  ## a suspension and given with `supply` or `supplyRetained`. `budget` is the
  ## work of one turn; `NoTurnBudget` never ends one.
  doAssert budget > 0, "a turn spends some work"
  let r = new Resolver
  r[].initResolver(input) # its setup is the run's first steps
  ResolverRun(r: r, steps: runSteps(r, root), budget: budget)

func largestStep*(run: ResolverRun): int64 =
  ## [IMPL-DECISION G455] (5-3c-3) The most work the run counted between two
  ## turn checks: what one of its turns can overrun the budget by. For the
  ## suites and the bench.
  run.r.largestStep

func numbered*(run: ResolverRun): tuple[records, contracts: int] =
  ## [IMPL-DECISION G455] (5-3c-3) The records whose contracts the run has
  ## numbered, and the contracts numbered: each once. For the suites.
  (run.r.lists.len, run.r.encodings.len)

when defined(lcnTestHooks):
  proc heldContractsForTests*(run: ResolverRun, source: PackageSource): int =
    ## Test hook (D27; DECISIONS I89) [IMPL-DECISION G482] (5-3c-4): the contracts the
    ## supplied inspection of `source` still holds (none once its walk took them); -1: none
    ## supplied, or not eligible.
    result = -1
    run.r.inspected.withValue(source.encoded, v):
      if v.kind == ikEligible:
        result = v[].contractCount

proc resume*(run: ResolverRun): Suspension =
  ## [IMPL-DECISION G455] Runs one turn: until the run needs something, its
  ## turn's work is spent, or it gives its outcome. Never after `suDone`.
  doAssert not run.steps.isNil, "a run is not resumed after its outcome"
  run.r.turnEnd =
    if run.budget > high(int64) - run.r.work:
      high(int64)
    else:
      run.r.work + run.budget
  result = run.steps()
  if result.kind == suDone:
    doAssert run.r.ended
    run.steps = nil # rule I6: the steps' environment goes with them

proc release*(run: ResolverRun): bool =
  ## [IMPL-DECISION G455] Frees one turn's work of what the run holds; true
  ## once all of it is freed. After the outcome, or instead of it: a run that
  ## is given up (its caller cancelled it) is not resumed again, and its steps
  ## are dropped at the first call. Each call is one turn, as `resume`'s.
  run.steps = nil
  if run.releasing.isNil:
    run.releasing = releaseSteps(run.r)
  run.r.turnEnd =
    if run.budget > high(int64) - run.r.work:
      high(int64)
    else:
      run.r.work + run.budget
  if run.releasing().kind == suDone:
    run.releasing = nil
    return true
  false

proc supply*(run: ResolverRun, source: PackageSource, inspection: sink Inspection) =
  ## The inspection of a source a `suNeedSource` named. Ignored once the run
  ## gave its outcome or is being released. [IMPL-DECISION G455] Taken, not
  ## copied: a maximum-size manifest's copy took milliseconds, in the handler
  ## that delivers it.
  ##
  ## [IMPL-DECISION G477] Its inputs count toward the operation bound here,
  ## once for each source: the run reads it when it is resumed.
  if not run.steps.isNil:
    let k = source.encoded
    if k notin run.r.inspected:
      run.r[].countRead(inspection.inputCount)
    run.r.inspected[k] = inspection

proc supplyRetained*(run: ResolverRun, record: int, answer: Result[void, string]) =
  ## The retained-bytes answer for the installed record a `suNeedRetained`
  ## named. Ignored once the run gave its outcome or is being released.
  if not run.steps.isNil:
    run.r.retainedAnswers[record] = answer

func supplied*(run: ResolverRun): int =
  ## The inspections supplied so far.
  run.r.inspected.len

func counters*(run: ResolverRun): ResolverCounters =
  run.r[].counters

func work*(run: ResolverRun): int64 =
  ## [IMPL-DECISION G454] The work units counted so far, the same for the same
  ## inputs whatever the budget.
  run.r.work

proc resolve*(
    input: ResolverInput,
    root: RootReference,
    counters: var ResolverCounters,
    work: var int64,
): Result[Resolution, PackageError] =
  ## [SPEC PM §11, §15] Resolves the complete transitive closure of `root`, or
  ## reports an update that changes nothing, or fails with
  ## `dependency-unavailable` (no closure, a conflict, or a limit reached),
  ## `package-unavailable` (material that could not be obtained, or the
  ## operation bound passed: [IMPL-DECISION G477]),
  ## `artifact-integrity-failed` (retained bytes absent or altered) or the
  ## root's own error. `counters` holds the counts either way; they depend only
  ## on the inputs. `work` is the number of work units the run counted
  ## ([IMPL-DECISION G454]), the same for the same inputs.
  ##
  ## [IMPL-DECISION G455] The run, driven to its end in one go: each need is
  ## answered by `input.inspect` and `input.retained` when it is asked for.
  doAssert not input.retained.isNil, "the retained-bytes check is required"
  let run = startRun(input, root, NoTurnBudget)
  while true:
    let s = run.resume()
    case s.kind
    of suNeedSource:
      run.supply(s.source, input.inspect(s.source, input.trust))
    of suNeedRetained:
      run.supplyRetained(s.record, input.retained(input.installed[s.record]))
    of suTurn:
      discard
    of suDone:
      counters = run.counters
      work = run.work
      return s.outcome

proc resolve*(
    input: ResolverInput, root: RootReference, counters: var ResolverCounters
): Result[Resolution, PackageError] =
  var work: int64
  resolve(input, root, counters, work)

proc resolve*(
    input: ResolverInput, root: RootReference
): Result[Resolution, PackageError] =
  var counters: ResolverCounters
  resolve(input, root, counters)

# LGX candidates --------------------------------------------------------------------

type Fetch* = proc(source: PackageSource): Opt[seq[byte]] {.gcsafe, raises: [].}
  ## Retrieves the archive a source locates; none when it cannot.

func inspection*(
    v: VerifiedPackage, modules: openArray[ModuleDeclaration]
): Inspection =
  ## [SPEC PM §11] An eligible record: its dependencies are the manifest's,
  ## unconditional across variants and modules, and it provides what
  ## `modules`, its selected declarations, provide (`provided`: once each).
  ## [IMPL-DECISION G482] Held as `eligibleInspection` holds them.
  eligibleInspection(
    v.manifest.identity, v.commitment, v.manifest.dependencies, provided(modules)
  )

func inspection*(p: LgxPackage): Inspection =
  ## [SPEC PM §11] [IMPL-DECISION I110] RG-7: an LGX record provides what the
  ## selected variant's module declarations provide.
  inspection(p.verified, p.modules)

proc lgxInspector*(
    fetch: Fetch,
    platform: Platform,
    limits = DefaultLgxLimits,
    pathRules = hostPathRules(),
): Inspector =
  ## [SPEC PM §7.1, §11] An LGX operation's candidates: a Nix source is not one
  ## (`unsupported-source`), an archive that cannot be retrieved is
  ## unavailable, and a record is eligible exactly when `openLgx` accepts it:
  ## archive, manifest, signature by an anchor of the resolver's trust input
  ## authorized for the exact package name, a compatible variant and its
  ## artifacts.
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
    let data = fetch(source).valueOr:
      return
        Inspection(kind: ikUnavailable, reason: "the archive could not be retrieved")
    let p = openLgx(data, trust, platform, limits, pathRules).valueOr:
      return Inspection(kind: ikIneligible, error: error)
    inspection(p)
