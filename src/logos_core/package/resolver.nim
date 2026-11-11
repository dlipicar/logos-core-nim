## PM §11: dependency resolution, sans-I/O. The installed state, the catalog
## entries and the protected resolver limits are inputs; candidate material is
## reached through an `Inspector` that the caller backs with retrieval and
## verification (`lgxInspector` does it for LGX). The result is one complete
## closure or an error: nothing is installed and no input changes.
##
## The search follows PM §11 exactly: the unresolved package name first in
## UTF-8 byte order, its satisfying candidates in descending SemVer precedence,
## chronological backtracking, and the four protected limits charged as the
## section defines them. It keeps its frames on the heap, so neither the
## result nor the counters depend on a native stack.

{.push raises: [].}

import std/[algorithm, sequtils, sets, tables]
import results
import ../cbor
import ./[errors, lgx, manifest, records, semver, signing, trust]

export results, errors, records

type
  ResolverLimits* = object
    ## [SPEC PM §11] Protected deployment policy's resolver-limit set. Only
    ## `resolverLimits` and `decodeResolverLimits` make one, so every limit is
    ## present and positive; no package, manifest, catalog, source or caller
    ## input reaches it.
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
    of ikIneligible:
      error*: PackageError
    of ikUnavailable:
      reason*: string

  Inspector* = proc(source: PackageSource): Inspection {.gcsafe, raises: [].}
    ## Locates, materializes and checks one source record: manifest commitment,
    ## realization profile, platform variant, signature (an accepted anchor
    ## authorized for the exact package name) and artifacts (PM §11). Called at
    ## most once per source record in one root operation.

  InstalledPackage* = object
    ## What resolution reads from one installed package record. An installed
    ## state holds each identity once (PM §15).
    identity*: PackageIdentity
    commitment*: ManifestCommitment
    dependencies*: seq[PackageDependency] ## its manifest's
    resolvedDependencies*: seq[ResolvedDependency] ## its recorded edges

  RootReference* = object
    ## The root of an operation: a package, a source, or both (PM §11, §15).
    package*: Opt[string]
    version*: Opt[string]
    source*: Opt[PackageSource]

  ResolverInput* = object
    installed*: seq[InstalledPackage]
    catalog*: seq[CatalogEntry]
    limits*: ResolverLimits
    inspect*: Inspector

  SelectedPackage* = object
    identity*: PackageIdentity
    commitment*: ManifestCommitment
    installed*: bool ## an installed record satisfies it: nothing to materialize
    source*: Opt[PackageSource] ## the selected source when one is needed
    depth*: int ## manifest dependency edges from the root when it was bound
    resolvedDependencies*: seq[ResolvedDependency]
      ## one exact edge per direct manifest dependency, in declaration order

  ResolverCounters* = object
    names*: int ## the largest partial closure
    depth*: int ## the greatest depth a candidate was bound at
    considered*: seq[(string, int)] ## candidates charged per package name, by name
    attempts*: int ## candidate-assignment attempts

  Resolution* = object
    root*: PackageIdentity
    packages*: seq[SelectedPackage] ## the closure, in package-name byte order
    counters*: ResolverCounters

# Limits ----------------------------------------------------------------------------

const ResolverLimitKeys* = [
  "assignment_attempts", "candidates_per_name", "dependency_depth",
  "partial_closure_names",
]
  ## [IMPL] The keys of the resolver-limit set in protected policy, in Logos
  ## deterministic-CBOR key order.

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
  ## [SPEC PM §11] Each limit is a positive integer; any other value is a
  ## protected-policy configuration failure, not a package error (PM §14).
  for (what, v) in [
    ("partial_closure_names", names),
    ("dependency_depth", depth),
    ("candidates_per_name", candidates),
    ("assignment_attempts", attempts),
  ]:
    if v <= 0:
      return err("resolver limit " & what & " is not positive")
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
  ## it: a map with exactly the `ResolverLimitKeys`, each a positive integer.
  ## A value above the native integer range counts as that range's maximum,
  ## which no counter reaches.
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
    found[name] = int64(min(n, uint64(high(int64))))
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

# The search state ------------------------------------------------------------------

type
  Req = object
    kind: RequirementKind
    version: string
    pin: Opt[ManifestCommitment]
      ## [IMPL-DECISION G167] the commitment of an installed dependent's
      ## recorded edge

  Cand = object
    identity: PackageIdentity
    commitment: ManifestCommitment
    installed: bool
    source: Opt[PackageSource]
    depNames: seq[string]
    deps: seq[Req]
    edges: Opt[seq[ResolvedDependency]] ## an installed candidate's recorded edges

  CatalogPick = object
    commitment: ManifestCommitment
    source: PackageSource
    deps: seq[PackageDependency]

  Eval = object
    catalog: Opt[CatalogPick] ## the selected commitment and source
    installed: int ## the installed record of the identity, or -1
    error: Opt[PackageError] ## the first ineligible record's

  Bound = object
    cand: Cand
    depth: int

  Frame = object
    name: string
    depth: int
    versions: seq[string]
    next: int
    bound: bool
    added: seq[string]

  Resolver = object
    installed: seq[InstalledPackage]
    catalog: seq[CatalogEntry]
    limits: ResolverLimits
    inspect: Inspector
    installedAt: Table[(string, string), int]
    entries: Table[(string, string), seq[int]] ## by ascending source encoding
    versions: Table[string, seq[string]] ## descending SemVer precedence
    inspected: Table[seq[byte], Inspection]
    evals: Table[(string, string), Eval]
    assigned: Table[string, Bound]
    reqs: Table[string, seq[Req]]
    charged: HashSet[(string, string)]
    considered: Table[string, int]
    attempts: int
    maxNames: int
    maxDepth: int

func key(id: PackageIdentity): (string, string) =
  (id.package, id.version)

func unavailableDependency(msg: string): PackageError =
  packageError(pecDependencyUnavailable, msg)

proc initResolver(input: ResolverInput): Resolver =
  doAssert input.limits.names > 0 and input.limits.depth > 0 and
    input.limits.candidates > 0 and input.limits.attempts > 0,
    "resolver limits come from resolverLimits or decodeResolverLimits"
  var r = Resolver(
    installed: input.installed,
    catalog: input.catalog,
    limits: input.limits,
    inspect: input.inspect,
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
    r.inspected[k] = r.inspect(s)
  r.inspected.getOrDefault(k)

proc evaluate(r: var Resolver, id: PackageIdentity): Result[Eval, PackageError] =
  ## [SPEC PM §11] Candidate eligibility and protected catalog commitment
  ## selection for one exact identity: every catalog record of it is
  ## inspected, in ascending source-record encoding. Unavailable material
  ## fails the root operation; it proves nothing about the candidate.
  if id.key in r.evals:
    return ok(r.evals.getOrDefault(id.key))
  var e = Eval(installed: r.installedAt.getOrDefault(id.key, -1))
  var picks: seq[CatalogPick]
  for i in r.entries.getOrDefault(id.key):
    let source = r.catalog[i].source
    let x = r.inspectSource(source)
    case x.kind
    of ikUnavailable:
      return err(packageError(pecPackageUnavailable, $id & ": " & x.reason))
    of ikIneligible:
      if e.error.isNone:
        e.error = Opt.some(x.error)
    of ikEligible:
      if x.identity != id:
        # [SPEC PM §2, §6] The manifest wins over catalog location data.
        if e.error.isNone:
          e.error = Opt.some(
            packageError(
              pecInvalidPackage, "the manifest declares " & $x.identity & ", not " & $id
            )
          )
      else:
        picks.add(
          CatalogPick(commitment: x.commitment, source: source, deps: x.dependencies)
        )
  if picks.len > 0:
    for p in picks:
      if p.commitment != picks[0].commitment:
        # [SPEC PM §11] [IMPL-DECISION G74] No protected catalog policy selects
        # one of several commitments.
        return err(
          unavailableDependency(
            "acceptable manifests claim " & $id &
              " with different commitments, and no protected catalog policy selects one"
          )
        )
    # [SPEC PM §11] Equivalent sources: the first in ascending encoding.
    e.catalog = Opt.some(picks[0])
  r.evals[id.key] = e
  ok(e)

func fresh(deps: seq[PackageDependency]): (seq[string], seq[Req]) =
  for d in deps:
    result[0].add(d.package)
    result[1].add(Req(kind: d.kind, version: d.version))

func pinned(edges: seq[ResolvedDependency]): (seq[string], seq[Req]) =
  ## [IMPL-DECISION G167] An installed candidate brings its recorded edges as
  ## exact identities and commitments; they are not resolved again.
  for e in edges:
    result[0].add(e.identity.package)
    result[1].add(
      Req(kind: rkExact, version: e.identity.version, pin: Opt.some(e.commitment))
    )

func dependencyCandidate(r: Resolver, id: PackageIdentity, e: Eval): Opt[Cand] =
  ## An installed record of the identity satisfies the dependency with its
  ## recorded edges; otherwise the selected catalog record does.
  if e.installed >= 0:
    let p = r.installed[e.installed]
    let (names, deps) = pinned(p.resolvedDependencies)
    Opt.some(
      Cand(
        identity: id,
        commitment: p.commitment,
        installed: true,
        depNames: names,
        deps: deps,
        edges: Opt.some(p.resolvedDependencies),
      )
    )
  elif e.catalog.isSome:
    let c = e.catalog.get
    let (names, deps) = fresh(c.deps)
    Opt.some(
      Cand(
        identity: id,
        commitment: c.commitment,
        source: Opt.some(c.source),
        depNames: names,
        deps: deps,
      )
    )
  else:
    Opt.none(Cand)

func rootCandidate(r: Resolver, id: PackageIdentity, e: Eval): Opt[Cand] =
  ## The root's edges are always selected afresh from its manifest; whether an
  ## installed record of the root conflicts is the operation's rule (PM §11,
  ## §15).
  if e.catalog.isSome:
    let c = e.catalog.get
    let (names, deps) = fresh(c.deps)
    Opt.some(
      Cand(
        identity: id,
        commitment: c.commitment,
        installed:
          e.installed >= 0 and r.installed[e.installed].commitment == c.commitment,
        source: Opt.some(c.source),
        depNames: names,
        deps: deps,
      )
    )
  elif e.installed >= 0:
    let p = r.installed[e.installed]
    let (names, deps) = fresh(p.dependencies)
    Opt.some(
      Cand(
        identity: id,
        commitment: p.commitment,
        installed: true,
        depNames: names,
        deps: deps,
      )
    )
  else:
    Opt.none(Cand)

func meets(c: Cand, q: Req): bool =
  satisfies(q.kind, q.version, c.identity.version) and
    (q.pin.isNone or q.pin.get == c.commitment)

func reaches(r: Resolver, start, target: string): bool =
  ## Whether `target` is reachable from `start` over bound packages' edges.
  var stack = @[start]
  var seen: HashSet[string]
  while stack.len > 0:
    let x = stack.pop()
    if x == target:
      return true
    if seen.containsOrIncl(x):
      continue
    for d in r.assigned.getOrDefault(x).cand.depNames:
      if d in r.assigned:
        stack.add(d)
  false

proc bindCand(
    r: var Resolver, name: string, c: Cand, depth: int, added: var seq[string]
): bool =
  ## Binds `c` and records its requirements. False when the partial closure is
  ## then rejected: a bound package does not satisfy a new requirement (one
  ## version per name), or an edge closes a cycle.
  r.assigned[name] = Bound(cand: c, depth: depth)
  r.maxNames = max(r.maxNames, r.assigned.len)
  r.maxDepth = max(r.maxDepth, depth)
  added.setLen(0)
  for i, d in c.depNames:
    r.reqs.mgetOrPut(d, @[]).add(c.deps[i])
    added.add(d)
  for i, d in c.depNames:
    if d in r.assigned:
      if not r.assigned.getOrDefault(d).cand.meets(c.deps[i]) or r.reaches(d, name):
        return false
  true

proc unbind(r: var Resolver, name: string, added: seq[string]) =
  r.assigned.del(name)
  for d in added:
    r.reqs.withValue(d, q):
      q[].setLen(q[].len - 1)
      if q[].len == 0:
        r.reqs.del(d)

func nextUnresolved(r: Resolver): Opt[string] =
  ## [SPEC PM §11] The unresolved package name first in UTF-8 byte order.
  var best = Opt.none(string)
  for name in r.reqs.keys:
    if name notin r.assigned and (best.isNone or name < best.get):
      best = Opt.some(name)
  best

func depthOf(r: Resolver, root, target: string): int =
  ## [SPEC PM §11] Manifest dependency edges from the root to `target` in the
  ## partial closure (breadth first: the fewest).
  var dist = {root: 0}.toTable
  var queue = @[root]
  var i = 0
  while i < queue.len:
    let x = queue[i]
    inc i
    for d in r.assigned.getOrDefault(x).cand.depNames:
      if d == target:
        return dist.getOrDefault(x) + 1
      if d in r.assigned and d notin dist:
        dist[d] = dist.getOrDefault(x) + 1
        queue.add(d)
  doAssert false, target & " is required by no bound package"
  -1

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
  ## [SPEC PM §11] A candidate is charged once per package name in one root
  ## operation, including when it is examined again after backtracking.
  if (name, version) in r.charged:
    return ok()
  let n = r.considered.getOrDefault(name)
  if n >= r.limits.candidates:
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
    return
      err(unavailableDependency("resolution exhausted the assignment-attempt limit"))
  inc r.attempts
  ok()

proc selectRoot(r: var Resolver, root: RootReference): Result[Cand, PackageError] =
  ## [SPEC PM §11, §15] A supplied source's verified manifest fixes the root;
  ## otherwise an explicit version does; otherwise the highest available normal
  ## release. The root is not a backtracking point.
  func invalidRequest(msg: string): PackageError =
    packageError(pecInvalidRequest, msg)

  if root.package.isNone and root.source.isNone:
    return err(invalidRequest("the root names a package, a source or both"))
  if root.version.isSome:
    if root.package.isNone:
      return err(invalidRequest("a root version needs a package"))
    parseSemVer(root.version.get).isOkOr:
      return err(invalidRequest("the root version is not a package version: " & error))
  if root.source.isSome:
    let x = r.inspectSource(root.source.get)
    case x.kind
    of ikUnavailable:
      return err(packageError(pecPackageUnavailable, "the root source: " & x.reason))
    of ikIneligible:
      return err(x.error)
    of ikEligible:
      if root.package.get(x.identity.package) != x.identity.package or
          root.version.get(x.identity.version) != x.identity.version:
        # [SPEC PM §8 l.1074-1079] a manifest that conflicts with the selected
        # package reference is an invalid package, not an invalid request
        return err(
          packageError(
            pecInvalidPackage, "the source's manifest declares " & $x.identity
          )
        )
      let (names, deps) = fresh(x.dependencies)
      let at = r.installedAt.getOrDefault(x.identity.key, -1)
      return ok(
        Cand(
          identity: x.identity,
          commitment: x.commitment,
          installed: at >= 0 and r.installed[at].commitment == x.commitment,
          source: root.source,
          depNames: names,
          deps: deps,
        )
      )
  let name = root.package.get
  if root.version.isSome:
    let id = PackageIdentity(package: name, version: root.version.get)
    let e = ?r.evaluate(id)
    let c = r.rootCandidate(id, e).valueOr:
      return
        err(e.error.get(packageError(pecPackageUnavailable, "no source holds " & $id)))
    return ok(c)
  var first = Opt.none(PackageError)
  for v in r.versions.getOrDefault(name):
    if parseSemVer(v).get.isPrerelease:
      continue # [SPEC PM §11] selected only by an explicit version or a source
    let id = PackageIdentity(package: name, version: v)
    let e = ?r.evaluate(id)
    let c = r.rootCandidate(id, e)
    if c.isSome:
      return ok(c.get)
    if first.isNone:
      first = e.error
  err(first.get(packageError(pecPackageUnavailable, "no normal release of " & name)))

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

func closure(r: Resolver, root: string): Resolution =
  var names: seq[string]
  for n in r.assigned.keys:
    names.add(n)
  names.sort()
  result.root = r.assigned.getOrDefault(root).cand.identity
  for n in names:
    let b = r.assigned.getOrDefault(n)
    var p = SelectedPackage(
      identity: b.cand.identity,
      commitment: b.cand.commitment,
      installed: b.cand.installed,
      source:
        if b.cand.installed:
          Opt.none(PackageSource)
        else:
          b.cand.source,
      depth: b.depth,
    )
    if b.cand.edges.isSome:
      p.resolvedDependencies = b.cand.edges.get
    else:
      for d in b.cand.depNames:
        let c = r.assigned.getOrDefault(d).cand
        p.resolvedDependencies.add(
          ResolvedDependency(identity: c.identity, commitment: c.commitment)
        )
    result.packages.add(p)
  result.counters = r.counters

proc run(r: var Resolver, root: RootReference): Result[Resolution, PackageError] =
  let rc = ?r.selectRoot(root)
  let rootName = rc.identity.package
  # [SPEC PM §11] The root counts toward the partial closure, at depth zero,
  # as one considered candidate and one assignment attempt.
  r.considered[rootName] = 1
  r.charged.incl(rc.identity.key)
  ?r.attempt()
  var rootAdded: seq[string]
  if not r.bindCand(rootName, rc, 0, rootAdded):
    return err(unavailableDependency("the root's own dependencies close a cycle"))

  var stack: seq[Frame]
  while true:
    let next = r.nextUnresolved()
    if next.isNone:
      return ok(r.closure(rootName))
    let name = next.get
    stack.add(
      Frame(name: name, depth: r.depthOf(rootName, name), versions: r.versionsFor(name))
    )
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
        if stack[f].depth > r.limits.depth:
          return err(
            unavailableDependency(
              "inspecting " & name & " at depth " & $stack[f].depth &
                " exceeds the dependency-depth limit"
            )
          )
        let id = PackageIdentity(package: name, version: version)
        let e = ?r.evaluate(id)
        let c = r.dependencyCandidate(id, e).valueOr:
          continue
        var meetsAll = true
        for q in r.reqs.getOrDefault(name):
          if not c.meets(q):
            meetsAll = false
            break
        if not meetsAll:
          continue
        ?r.charge(name, version)
        if e.installed >= 0 and e.catalog.isSome and
            e.catalog.get.commitment != c.commitment:
          # [SPEC PM §11] Not skipped and not resolved by backtracking.
          return err(
            unavailableDependency(
              $id & " is installed with another manifest commitment than the catalog's"
            )
          )
        if r.assigned.len + 1 > r.limits.names:
          return err(
            unavailableDependency(
              "adding " & name & " exceeds the partial-closure package-name limit"
            )
          )
        ?r.attempt()
        if r.bindCand(name, c, stack[f].depth, stack[f].added):
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
  ## [SPEC PM §11] Resolves the complete transitive closure of `root`, or fails
  ## with `dependency-unavailable` (no closure, or a limit reached),
  ## `package-unavailable` (material that could not be obtained) or the root's
  ## own error. `counters` holds the counts either way; they depend only on the
  ## inputs.
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

func inspection*(v: VerifiedPackage): Inspection =
  ## [SPEC PM §11] An eligible record: its dependencies are the manifest's,
  ## unconditional across variants and modules, and nothing else.
  Inspection(
    kind: ikEligible,
    identity: v.manifest.identity,
    commitment: v.commitment,
    dependencies: v.manifest.dependencies,
  )

proc lgxInspector*(
    fetch: Fetch,
    trust: TrustInput,
    platform: Platform,
    limits = DefaultLgxLimits,
    pathRules = hostPathRules(),
): Inspector =
  ## [SPEC PM §7.1, §11] An LGX operation's candidates: a Nix source is not one
  ## (`unsupported-source`), an archive that cannot be retrieved is
  ## unavailable, and a record is eligible exactly when `openLgx` accepts it:
  ## archive, manifest, signature by an anchor authorized for the exact
  ## package name, a compatible variant and its artifacts.
  result = proc(source: PackageSource): Inspection {.gcsafe, raises: [].} =
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
    inspection(p.verified)
