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

{.push raises: [].}

import std/[algorithm, sequtils, sets, tables]
import results
import logos_sdk/cbor
import logos_sdk/base/testhooks
import ./[errors, lgx, manifest, records, semver, signing, trust]

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

  Inspection* = object ## What one source record yields for the requested operation.
    case kind*: InspectionKind
    of ikEligible:
      identity*: PackageIdentity ## the verified manifest's
      commitment*: ManifestCommitment
      dependencies*: seq[PackageDependency] ## the manifest's, in declaration order
      provides*: seq[CborValue]
        ## [SPEC PM §11 l.1213] the contracts its selected module declarations
        ## provide (`provided`)
    of ikIneligible:
      error*: PackageError
    of ikUnavailable:
      reason*: string

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

  Resolution* = object
    root*: PackageIdentity
    unchanged*: bool
      ## an update found no applicable newer version: `root` is `current` and
      ## `packages` is empty (PM l.1705)
    packages*: seq[SelectedPackage] ## the closure, in package-name byte order
    counters*: ResolverCounters

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
  Req = object
    kind: RequirementKind
    version: string
    pin: Opt[ManifestCommitment]
      ## [SPEC PM §11 l.1304] the commitment of an installed dependent's
      ## recorded edge
    contracts: seq[seq[byte]]
      ## [SPEC PM §11 l.1215] the encodings of the contracts it lists

  Cand = object
    identity: PackageIdentity
    commitment: ManifestCommitment
    installed: bool
    source: Opt[PackageSource]
    depNames: seq[string]
    deps: seq[Req]
    edges: Opt[seq[ResolvedDependency]] ## an installed candidate's recorded edges
    provides: HashSet[seq[byte]]

  CatalogPick = object
    commitment: ManifestCommitment
    source: PackageSource
    deps: seq[PackageDependency]
    provides: HashSet[seq[byte]]

  Eval = object
    picks: seq[CatalogPick]
      ## every eligible catalog record of the identity, in ascending source
      ## encoding
    installed: int ## the installed record of the identity, or -1
    installedError: Opt[PackageError] ## why that record is ineligible
    errors: seq[PackageError] ## every ineligible catalog record's reason, in order

  Frame = object
    name: string
    versions: seq[string]
    next: int
    bound: bool
    added: seq[string]

  Resolver = object
    installed: seq[InstalledPackage]
    catalog: seq[CatalogEntry]
    limits: ResolverLimits
    trust: TrustInput
    inspect: Inspector
    retained: RetainedCheck
    installedAt: Table[(string, string), int]
    entries: Table[(string, string), seq[int]] ## by ascending source encoding
    versions: Table[string, seq[string]] ## descending SemVer precedence
    inspected: Table[seq[byte], Inspection]
    evals: Table[(string, string), Eval]
    assigned: Table[string, Cand]
    reqs: Table[string, seq[Req]]
    root: string
    depths: Table[string, int]
      ## every bound name and every name a bound package requires
    depthsStale: bool
    charged: HashSet[(string, string)]
    considered: Table[string, int]
    attempts: int
    maxNames: int
    maxDepth: int
    tripped: string ## the limit that ended the run (`ResolverCounters.limit`)

func key(id: PackageIdentity): (string, string) =
  (id.package, id.version)

func unavailableDependency(msg: string): PackageError =
  packageError(pecDependencyUnavailable, msg)

func invalidRequest(msg: string): PackageError =
  packageError(pecInvalidRequest, msg)

func contractKeys(cs: openArray[CborValue]): HashSet[seq[byte]] =
  for c in cs:
    result.incl(encodeCbor(c))

proc initResolver(input: ResolverInput): Resolver =
  let l = input.limits
  doAssert l.names > 0 and l.depth > 0 and l.candidates > 0 and l.attempts > 0 and
    l.names <= MaxResolverLimits.names and l.depth <= MaxResolverLimits.depth and
    l.candidates <= MaxResolverLimits.candidates and
    l.attempts <= MaxResolverLimits.attempts,
    "resolver limits come from resolverLimits or decodeResolverLimits"
  doAssert not input.retained.isNil, "the retained-bytes check is required"
  var r = Resolver(
    installed: input.installed,
    catalog: input.catalog,
    limits: input.limits,
    trust: input.trust,
    inspect: input.inspect,
    retained: input.retained,
  )
  var parsed: Table[string, SemVer]
  proc note(r: var Resolver, id: PackageIdentity): bool =
    let v = parseSemVer(id.version).valueOr:
      return false
    parsed[id.version] = v
    r.versions.withValue(id.package, known):
      if id.version notin known[]:
        known[].add(id.version)
    do:
      r.versions[id.package] = @[id.version]
    true

  for i, p in r.installed:
    doAssert p.identity.key notin r.installedAt,
      "an installed state holds " & $p.identity & " once"
    if r.note(p.identity):
      r.installedAt[p.identity.key] = i
  var seen: HashSet[seq[byte]]
  for i, e in r.catalog:
    let dup = encodeCbor(e.toCbor)
    if seen.containsOrIncl(dup) or not r.note(e.identity):
      continue
    r.entries.mgetOrPut(e.identity.key, @[]).add(i)
  let encodings = r.catalog.mapIt(it.source.encoded)
  for group in r.entries.mvalues:
    group.sort(
      proc(a, b: int): int =
        cmpBytes(encodings[a], encodings[b])
    )
  for vs in r.versions.mvalues:
    vs.sort(
      proc(a, b: string): int =
        cmp(parsed.getOrDefault(b), parsed.getOrDefault(a))
    )
  r

proc inspectSource(r: var Resolver, s: PackageSource): Inspection =
  let k = s.encoded
  if k notin r.inspected:
    r.inspected[k] = r.inspect(s, r.trust)
  r.inspected.getOrDefault(k)

func known(r: Resolver, id: PackageIdentity): bool =
  id.key in r.installedAt or id.key in r.entries

proc evaluate(r: var Resolver, id: PackageIdentity): Result[Eval, PackageError] =
  ## [SPEC PM §11] Candidate eligibility for one exact identity: the installed
  ## record and every catalog record of it, in ascending source-record
  ## encoding. Every reason is kept, the installed record's first. Unavailable
  ## material and altered retained bytes fail the root operation; neither is
  ## ineligibility.
  if id.key in r.evals:
    return ok(r.evals.getOrDefault(id.key))
  var e = Eval(installed: r.installedAt.getOrDefault(id.key, -1))
  if e.installed >= 0:
    let p = r.installed[e.installed]
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
      r.retained(p).isOkOr:
        # [SPEC PM §11 l.1302-1303]
        return
          err(packageError(pecArtifactIntegrity, "the installed " & $id & ": " & error))
      if not r.trust.accepts(p.signer, id.package):
        # [SPEC PM §11 l.1292-1293] [IMPL-DECISION G166] A withdrawn signer.
        e.installedError = Opt.some(
          packageError(
            pecSignature,
            "the retained signer of the installed " & $id &
              " is not an accepted signer authorized for " & id.package,
          )
        )
  for i in r.entries.getOrDefault(id.key):
    let source = r.catalog[i].source
    let x = r.inspectSource(source)
    case x.kind
    of ikUnavailable:
      return err(packageError(pecPackageUnavailable, $id & ": " & x.reason))
    of ikIneligible:
      e.errors.add(x.error)
    of ikEligible:
      if x.identity != id:
        # [SPEC PM §2, §6] The manifest wins over catalog location data.
        e.errors.add(
          packageError(
            pecInvalidPackage, "the manifest declares " & $x.identity & ", not " & $id
          )
        )
      else:
        e.picks.add(
          CatalogPick(
            commitment: x.commitment,
            source: source,
            deps: x.dependencies,
            provides: contractKeys(x.provides),
          )
        )
  r.evals[id.key] = e
  ok(e)

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

func fresh(deps: seq[PackageDependency]): (seq[string], seq[Req]) =
  for d in deps:
    result[0].add(d.package)
    result[1].add(
      Req(
        kind: d.kind, version: d.version, contracts: d.contracts.mapIt(encodeCbor(it))
      )
    )

func pinned(edges: seq[ResolvedDependency]): (seq[string], seq[Req]) =
  ## [SPEC PM §11 l.1304] An installed candidate brings its recorded edges as
  ## exact identities and commitments; they are not resolved again, and they
  ## carry no contracts.
  for e in edges:
    result[0].add(e.identity.package)
    result[1].add(
      Req(kind: rkExact, version: e.identity.version, pin: Opt.some(e.commitment))
    )

func meets(c: Cand, q: Req): bool =
  satisfies(q.kind, q.version, c.identity.version) and
    (q.pin.isNone or q.pin.get == c.commitment) and q.contracts.allIt(it in c.provides)

func pinsFor(r: Resolver, name: string): seq[ManifestCommitment] =
  for q in r.reqs.getOrDefault(name):
    if q.pin.isSome and q.pin.get notin result:
      result.add(q.pin.get)

func allows(pins: seq[ManifestCommitment], c: ManifestCommitment): bool =
  pins.allIt(it == c)

func needed(r: Resolver, name: string): seq[seq[byte]] =
  for q in r.reqs.getOrDefault(name):
    for c in q.contracts:
      if c notin result:
        result.add(c)

func excludedByKnownCommitment(
    r: Resolver, id: PackageIdentity, pins: seq[ManifestCommitment]
): bool =
  ## [SPEC PM §11 l.1305-1306] Every record of the identity has a known
  ## commitment that a pin excludes: it is neither considered nor charged. A
  ## catalog record not yet inspected has no known commitment.
  if pins.len == 0:
    return false
  let at = r.installedAt.getOrDefault(id.key, -1)
  if at >= 0 and pins.allows(r.installed[at].commitment):
    return false
  for i in r.entries.getOrDefault(id.key):
    let k = r.catalog[i].source.encoded
    if k notin r.inspected:
      return false
    let x = r.inspected.getOrDefault(k)
    if x.kind != ikEligible or x.identity != id or pins.allows(x.commitment):
      return false
  true

proc dependencyCandidate(
    r: Resolver, id: PackageIdentity, e: Eval
): Result[Opt[Cand], PackageError] =
  ## [SPEC PM §11 l.1294-1310] The candidate for a reached dependency identity,
  ## after eligibility, the accumulated pins and contracts, commitment
  ## selection and the installed-identity conflict check.
  let pins = r.pinsFor(id.package)
  let need = r.needed(id.package)
  var allowed: seq[CatalogPick]
  for p in e.picks:
    # [IMPL-DECISION I110] Pins apply per record (Q8): a pinned version the
    # catalog lists under another commitment is not a candidate.
    if pins.allows(p.commitment) and need.allIt(it in p.provides):
      allowed.add(p)
  for p in allowed:
    if p.commitment != allowed[0].commitment:
      # [SPEC PM §11] [IMPL-DECISION G74] No protected catalog policy selects
      # one of several commitments.
      return err(
        unavailableDependency(
          "acceptable manifests claim " & $id &
            " with different commitments, and no protected catalog policy selects one"
        )
      )
  if e.installed >= 0:
    let p = r.installed[e.installed]
    if allowed.len > 0 and allowed[0].commitment != p.commitment:
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
      provides: contractKeys(provided(p.modules)),
    )
    if e.installedError.isNone and pins.allows(p.commitment) and
        need.allIt(it in c.provides):
      return ok(Opt.some(c))
    if allowed.len > 0:
      # [IMPL-DECISION I110] B7: an eligible catalog record of the installed
      # commitment satisfies the identity; it stays installed, with its
      # recorded edges and its retained signer (replacing it is PKG-0608's).
      c.provides = allowed[0].provides
      return ok(Opt.some(c))
    return ok(Opt.none(Cand))
  if allowed.len > 0:
    let (names, deps) = fresh(allowed[0].deps)
    return ok(
      Opt.some(
        Cand(
          identity: id,
          commitment: allowed[0].commitment,
          source: Opt.some(allowed[0].source),
          depNames: names,
          deps: deps,
          provides: allowed[0].provides,
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
    let c = e.picks[0]
    let (names, deps) = fresh(c.deps)
    return ok(
      Opt.some(
        Cand(
          identity: id,
          commitment: c.commitment,
          installed:
            e.installed >= 0 and r.installed[e.installed].commitment == c.commitment,
          source: Opt.some(c.source),
          depNames: names,
          deps: deps,
          provides: c.provides,
        )
      )
    )
  if e.installed >= 0 and e.installedError.isNone:
    let p = r.installed[e.installed]
    let (names, deps) = fresh(p.dependencies)
    return ok(
      Opt.some(
        Cand(
          identity: id,
          commitment: p.commitment,
          installed: true,
          depNames: names,
          deps: deps,
          provides: contractKeys(provided(p.modules)),
        )
      )
    )
  ok(Opt.none(Cand))

func reachesAny(r: Resolver, starts: openArray[string], target: string): bool =
  ## Whether `target` is reachable over bound packages' edges from any bound
  ## name of `starts`. [IMPL; planning's ruling of 2026-11-22, 7.2] One walk
  ## with one visited set, so a candidate that requires many bound names costs
  ## the edges they reach once, not once per name.
  var stack: seq[string]
  for x in starts:
    if x in r.assigned:
      stack.add(x)
  var seen: HashSet[string]
  while stack.len > 0:
    let x = stack.pop()
    if x == target:
      return true
    if seen.containsOrIncl(x):
      continue
    for d in r.assigned.getOrDefault(x).depNames:
      if d in r.assigned:
        stack.add(d)
  false

when defined(lcnTestHooks):
  var perDependencyWalk* {.threadvar.}: bool
    ## A test hook: `bindCand`'s cycle check as 5-3b-1 built it, one walk per
    ## bound dependency, for the test that compares the two (`test_resolver`).

  func reaches(r: Resolver, start, target: string): bool =
    r.reachesAny([start], target)

proc bindCand(r: var Resolver, name: string, c: Cand, added: var seq[string]): bool =
  ## Binds `c` and records its requirements. False when the partial closure is
  ## then rejected: a bound package does not satisfy a new requirement (one
  ## version per name, a pin, a contract), or an edge closes a cycle.
  r.assigned[name] = c
  r.maxNames = max(r.maxNames, r.assigned.len)
  added.setLen(0)
  for i, d in c.depNames:
    r.reqs.mgetOrPut(d, @[]).add(c.deps[i])
    added.add(d)
  for i, d in c.depNames:
    if d in r.assigned and not r.assigned.getOrDefault(d).meets(c.deps[i]):
      return false
  # Both checks only reject, so their order does not change the answer.
  when defined(lcnTestHooks):
    if perDependencyWalk:
      for d in c.depNames:
        if d in r.assigned and r.reaches(d, name):
          return false
      return true
  not r.reachesAny(c.depNames, name)

proc unbind(r: var Resolver, name: string, added: seq[string]) =
  r.assigned.del(name)
  r.depthsStale = true
  for d in added:
    r.reqs.withValue(d, q):
      q[].setLen(q[].len - 1)
      if q[].len == 0:
        r.reqs.del(d)

proc computeDepths(r: var Resolver) =
  ## [SPEC PM §11 l.1256] The greatest number of edges on any path from the
  ## root, for every bound name and every name a bound package requires.
  ## The partial closure is acyclic (`bindCand`), so a longest path exists;
  ## Kahn's order computes it without recursion.
  var indegree: Table[string, int]
  for c in r.assigned.values:
    for d in c.depNames:
      indegree.mgetOrPut(d, 0).inc
  var depths = {r.root: 0}.toTable
  var queue = @[r.root]
  var i = 0
  while i < queue.len:
    let x = queue[i]
    inc i
    if x notin r.assigned:
      continue # a required name with no candidate yet
    let dx = depths.getOrDefault(x)
    for d in r.assigned.getOrDefault(x).depNames:
      depths[d] = max(depths.getOrDefault(d), dx + 1)
      indegree.withValue(d, n):
        dec n[]
        if n[] == 0:
          queue.add(d)
  doAssert queue.len == depths.len, "the partial closure is acyclic"
  r.depths = depths
  r.depthsStale = false

proc depthOf(r: var Resolver, name: string): int =
  if r.depthsStale:
    r.computeDepths()
  r.depths.getOrDefault(name)

proc settleDepths(r: var Resolver): Result[void, PackageError] =
  ## [SPEC PM §11 l.1257-1260, l.1276-1277] After a bind: an edge that deepens
  ## a bound name deepens the names it requires, so every bound and required
  ## name is checked. A name over the limit terminates the root operation; it
  ## is not backtracked.
  r.computeDepths()
  var over = Opt.none(string)
  for n, d in r.depths:
    if n in r.assigned:
      r.maxDepth = max(r.maxDepth, d)
    if d > r.limits.depth and (over.isNone or n < over.get):
      over = Opt.some(n)
  if over.isSome:
    let n = over.get
    # [ruling S1] No depth in the message: it would show the limit, which is
    # protected policy input (PM l.1514), to the caller.
    r.tripped = "dependency_depth"
    return err(unavailableDependency(n & " is beyond the dependency-depth limit"))
  ok()

func versionsFor(r: Resolver, name: string): seq[string] =
  ## [SPEC PM §11] Versions satisfying every accumulated requirement, in
  ## descending SemVer precedence.
  let reqs = r.reqs.getOrDefault(name)
  for v in r.versions.getOrDefault(name):
    var ok = true
    for q in reqs:
      if not satisfies(q.kind, q.version, v):
        ok = false
        break
    if ok:
      result.add(v)

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
  let x = r.inspectSource(root.source.get)
  case x.kind
  of ikUnavailable:
    return err(packageError(pecPackageUnavailable, "the root source: " & x.reason))
  of ikIneligible:
    return err(x.error)
  of ikEligible:
    discard
  if package.get(x.identity.package) != x.identity.package or
      root.version.get(x.identity.version) != x.identity.version:
    # [SPEC PM §8 l.1074-1079] a manifest that conflicts with the selected
    # package reference is an invalid package, not an invalid request
    return err(
      packageError(pecInvalidPackage, "the source's manifest declares " & $x.identity)
    )
  ?r.charge(x.identity.package, x.identity.version)
  let (names, deps) = fresh(x.dependencies)
  let at = r.installedAt.getOrDefault(x.identity.key, -1)
  ok(
    Cand(
      identity: x.identity,
      commitment: x.commitment,
      installed: at >= 0 and r.installed[at].commitment == x.commitment,
      source: root.source,
      depNames: names,
      deps: deps,
      provides: contractKeys(x.provides),
    )
  )

proc versionRoot(r: var Resolver, id: PackageIdentity): Result[Cand, PackageError] =
  if not r.known(id):
    return err(packageError(pecPackageUnavailable, "no source holds " & $id))
  ?r.charge(id.package, id.version)
  let e = ?r.evaluate(id)
  let c = ?r.rootCandidate(id, e)
  if c.isNone:
    return err(e.firstError.get(packageError(pecPackageUnavailable, $id)))
  ok(c.get)

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
  for v in r.versions.getOrDefault(name):
    if parseSemVer(v).get.isPrerelease:
      continue # [SPEC PM §11] selected only by an explicit version or a source
    if root.newerThan.isSome and not v.newerThan(root.newerThan.get.version):
      break # descending: no newer version is left
    let id = PackageIdentity(package: name, version: v)
    ?r.charge(name, v)
    let e = ?r.evaluate(id)
    let c = ?r.rootCandidate(id, e)
    if c.isSome:
      return ok(c)
    if root.newerThan.isSome and e.unsupportedOnly:
      continue # [SPEC PM §15 l.1707] not applicable
    if first.isNone:
      first = e.firstError
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

proc closure(r: var Resolver): Resolution =
  if r.depthsStale:
    r.computeDepths()
  var names: seq[string]
  for n in r.assigned.keys:
    names.add(n)
  names.sort()
  result.root = r.assigned.getOrDefault(r.root).identity
  for n in names:
    let c = r.assigned.getOrDefault(n)
    var p = SelectedPackage(
      identity: c.identity,
      commitment: c.commitment,
      installed: c.installed,
      source:
        if c.installed and n != r.root:
          Opt.none(PackageSource)
        else:
          # [SPEC PM §15 l.1686-1687] The root's selected or supplied source is
          # kept even when it is installed: its signature is the request's.
          c.source,
      depth: r.depths.getOrDefault(n),
    )
    if c.edges.isSome:
      p.resolvedDependencies = c.edges.get
    else:
      for d in c.depNames:
        let b = r.assigned.getOrDefault(d)
        p.resolvedDependencies.add(
          ResolvedDependency(identity: b.identity, commitment: b.commitment)
        )
    result.packages.add(p)
  result.counters = r.counters

proc run(r: var Resolver, root: RootReference): Result[Resolution, PackageError] =
  let picked = ?r.selectRoot(root)
  if picked.isNone:
    return
      ok(Resolution(root: root.newerThan.get, unchanged: true, counters: r.counters))
  let rc = picked.get
  r.root = rc.identity.package
  # [SPEC PM §11] The root counts toward the partial closure, at depth zero; it
  # was charged when it was examined, and binding it is an attempt.
  ?r.attempt()
  var rootAdded: seq[string]
  if not r.bindCand(r.root, rc, rootAdded):
    return err(unavailableDependency("the root's own dependencies close a cycle"))
  ?r.settleDepths()

  var stack: seq[Frame]
  while true:
    var next = Opt.none(string)
    for name in r.reqs.keys:
      # [SPEC PM §11] The unresolved package name first in UTF-8 byte order.
      if name notin r.assigned and (next.isNone or name < next.get):
        next = Opt.some(name)
    if next.isNone:
      return ok(r.closure())
    stack.add(Frame(name: next.get, versions: r.versionsFor(next.get)))
    var placed = false
    while stack.len > 0 and not placed:
      let f = stack.len - 1
      if stack[f].bound:
        r.unbind(stack[f].name, stack[f].added)
        stack[f].bound = false
      while stack[f].next < stack[f].versions.len:
        let name = stack[f].name
        let version = stack[f].versions[stack[f].next]
        inc stack[f].next
        let depth = r.depthOf(name)
        if depth > r.limits.depth:
          r.tripped = "dependency_depth" # [ruling S1] no depth in the message
          return err(
            unavailableDependency(
              "inspecting " & name & " exceeds the dependency-depth limit"
            )
          )
        let id = PackageIdentity(package: name, version: version)
        if (name, version) notin r.charged and
            r.excludedByKnownCommitment(id, r.pinsFor(name)):
          continue
        ?r.charge(name, version)
        let e = ?r.evaluate(id)
        let c = (?r.dependencyCandidate(id, e)).valueOr:
          continue
        if r.assigned.len + 1 > r.limits.names:
          r.tripped = "partial_closure_names"
          return err(
            unavailableDependency(
              "adding " & name & " exceeds the partial-closure package-name limit"
            )
          )
        ?r.attempt()
        if r.bindCand(name, c, stack[f].added):
          ?r.settleDepths()
          stack[f].bound = true
          placed = true
          break
        r.unbind(name, stack[f].added)
      if not placed:
        discard stack.pop()
    if not placed:
      return err(unavailableDependency("no complete dependency closure exists"))

proc resolve*(
    input: ResolverInput, root: RootReference, counters: var ResolverCounters
): Result[Resolution, PackageError] =
  ## [SPEC PM §11, §15] Resolves the complete transitive closure of `root`, or
  ## reports an update that changes nothing, or fails with
  ## `dependency-unavailable` (no closure, a conflict, or a limit reached),
  ## `package-unavailable` (material that could not be obtained),
  ## `artifact-integrity-failed` (retained bytes absent or altered) or the
  ## root's own error. `counters` holds the counts either way; they depend only
  ## on the inputs.
  var r = initResolver(input)
  result = r.run(root)
  counters = r.counters

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
  ## `modules`, its selected declarations, provide.
  Inspection(
    kind: ikEligible,
    identity: v.manifest.identity,
    commitment: v.commitment,
    dependencies: v.manifest.dependencies,
    provides: provided(modules),
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
