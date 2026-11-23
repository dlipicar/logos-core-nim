## The resolver's inspection with its contracts as values (Tier 5 step 5-3c-4; DECISIONS G482,
## G454): the shape `Inspection` had before G482, kept on the test side. The tests and the
## bench's shapes write their answers in it; the resolution oracle (`oracle_resolver.nim`)
## reads it, as it always did; the resolver is given the same answers held as it holds them
## (`held`, through `eligibleInspection`). `held` checks the encodings against the values it
## was given, so every suite that compares the resolver with the oracle checks the builder.

{.push raises: [].}

import results
import logos_sdk/cbor
import
  ../../src/logos_core/package/
    [errors, lgx, manifest, records, resolver, signing, trust]

type
  ValueInspection* = object
    ## What one source record yields, its contracts as values (the pre-G482 `Inspection`).
    case kind*: InspectionKind
    of ikEligible:
      identity*: PackageIdentity
      commitment*: ManifestCommitment
      dependencies*: seq[PackageDependency]
      provides*: seq[CborValue]
    of ikIneligible:
      error*: PackageError
    of ikUnavailable:
      reason*: string

  ValueInspector* = proc(source: PackageSource, trust: TrustInput): ValueInspection {.
    gcsafe, raises: []
  .}

func valueInspection*(
    v: VerifiedPackage, modules: openArray[ModuleDeclaration]
): ValueInspection =
  ## `resolver.inspection(v, modules)` as values: the manifest's dependencies, and
  ## `provided(modules)`.
  ValueInspection(
    kind: ikEligible,
    identity: v.manifest.identity,
    commitment: v.commitment,
    dependencies: v.manifest.dependencies,
    provides: provided(modules),
  )

func valueInspection*(p: LgxPackage): ValueInspection =
  valueInspection(p.verified, p.modules)

func encodings*(x: Inspection): (seq[seq[seq[byte]]], seq[seq[byte]]) =
  ## Each entry's listed encodings, and the provided ones, as `seq`s.
  result[0].setLen(x.dependencies.len)
  for (entry, at) in x.contractRanges:
    let enc = @(x.contractData.toOpenArrayByte(at.a, at.b))
    if entry >= 0:
      result[0][entry].add(enc)
    else:
      result[1].add(enc)

func encodings*(v: ValueInspection): (seq[seq[seq[byte]]], seq[seq[byte]]) =
  for d in v.dependencies:
    var listed: seq[seq[byte]]
    for c in d.contracts:
      listed.add(encodeCbor(c))
    result[0].add(listed)
  for c in v.provides:
    result[1].add(encodeCbor(c))

func matches*(x: Inspection, v: ValueInspection): bool =
  ## Whether `x` holds what `v` says, field by field, each contract by its encoding.
  if x.kind != v.kind:
    return false
  case v.kind
  of ikEligible:
    if x.identity != v.identity or x.commitment != v.commitment or
        x.dependencies.len != v.dependencies.len:
      return false
    for i, d in v.dependencies:
      let h = x.dependencies[i]
      if h.package != d.package or h.kind != d.kind or h.version != d.version or
          h.listedCount != d.contracts.len:
        return false
    x.providedCount == v.provides.len and x.encodings == v.encodings
  of ikIneligible:
    x.error == v.error
  of ikUnavailable:
    x.reason == v.reason

func values*(x: Inspection): ValueInspection =
  ## `x` with its contracts decoded back to values: the inverse of `held`.
  case x.kind
  of ikEligible:
    result =
      ValueInspection(kind: ikEligible, identity: x.identity, commitment: x.commitment)
    for d in x.dependencies:
      result.dependencies.add(
        PackageDependency(package: d.package, kind: d.kind, version: d.version)
      )
    for (entry, at) in x.contractRanges:
      let v = decodeCbor(x.contractData.toOpenArrayByte(at.a, at.b))
      doAssert v.isOk, "an inspection's encodings decode"
      if entry >= 0:
        result.dependencies[entry].contracts.add(v.get)
      else:
        result.provides.add(v.get)
  of ikIneligible:
    result = ValueInspection(kind: ikIneligible, error: x.error)
  of ikUnavailable:
    result = ValueInspection(kind: ikUnavailable, reason: x.reason)

func valueUnits*(v: ValueInspection): seq[InputUnit] =
  ## G477's walk as it was over values: the record, each dependency entry followed by the
  ## contracts it lists, then each provided contract, a contract's bytes its `encodedSize`.
  case v.kind
  of ikEligible:
    result.add((iuRecord, v.identity.package.len + v.identity.version.len))
    for d in v.dependencies:
      result.add((iuDependency, d.package.len + d.version.len))
      for c in d.contracts:
        result.add((iuDependencyContract, encodedSize(c)))
    for c in v.provides:
      result.add((iuProvided, encodedSize(c)))
  of ikIneligible:
    result.add((iuRecord, v.error.msg.len))
  of ikUnavailable:
    result.add((iuRecord, v.reason.len))

func held*(v: ValueInspection, check = true): Inspection =
  ## `v` as the resolver holds it (`eligibleInspection`), checked against `v` unless `check`
  ## is false (the bench, whose figures leave the check out).
  result =
    case v.kind
    of ikEligible:
      eligibleInspection(v.identity, v.commitment, v.dependencies, v.provides)
    of ikIneligible:
      Inspection(kind: ikIneligible, error: v.error)
    of ikUnavailable:
      Inspection(kind: ikUnavailable, reason: v.reason)
  if check:
    doAssert result.matches(v),
      "eligibleInspection holds the values it was given (G482)"

func resolverInspector*(inspect: ValueInspector): Inspector =
  ## The resolver's inspector over the same answers.
  result = proc(
      source: PackageSource, trust: TrustInput
  ): Inspection {.gcsafe, raises: [].} =
    held(inspect(source, trust))

{.pop.}
