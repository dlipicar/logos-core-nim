## The worker's jobs (Tier 5 step 5-5-3; DECISIONS G447; docs/PACKAGE-MANAGER.md
## §10): what crosses between the module thread and the worker, and how each job
## runs. Portable, with no thread: `worker.nim` runs `runJob` on the worker
## thread, and the engine's tests run it inline (`tests/support/pmworld.nim`).
##
## - **No reference crosses** (Fable's recheck of draft 2, §4): a message is
##   copied under refc and moved under orc, and a reference that may be part of
##   a cycle belongs to one thread's collector. `refFree` walks a type at compile
##   time and this module asserts it of `WorkerJob` and `WorkerResult`: no `ref`,
##   `ptr`, `pointer`, closure or `cstring`, at any depth.
## - **An inspection crosses encoded** (G447, D1; planning accepted it with Fable's
##   conditions, 2026-11-23): the
##   resolver's `Inspection` holds its contracts as `CborValue`s, which are
##   references, so `WireOpened` carries each as its deterministic encoding, and
##   the module thread decodes them back (`Decoding`), at most `DecodeTurnUnits`
##   a turn, counted as G477's walk counts them: a dependency entry and a
##   contract are a unit each. A 4 MiB manifest holds at most about 80,000
##   entries or about 22,000 commitments: about 24 ms to decode the commitments
##   under orc and 40 ms under refc in all (the Mac, `-d:release`), so about 1 to
##   2 ms a turn.
## - **Bytes cross as `string`s** (a chunk, a contract's encoding): refc's channel copies a
##   `seq[byte]` one element at a time, 3.4 ms for a 1 MiB chunk on the Mac, and a `string`
##   in one block. Under orc a message is moved.
## - **The jobs**, in order on one thread: `wjStart` (the worker's own copy of
##   the trust input, the platform, the LGX limits, the path rules and the spool
##   directory, taken at open), `wjAppend` (a spool file's next piece; the first
##   creates it), `wjFinish` (its digest), `wjOpen` (the inspection pass over it,
##   `vcache.judge`), `wjDrop` (delete it) and `wjQuit`.

{.push raises: [].}

import std/[macros, tables]
import results
import logos_sdk/cbor
import logos_sdk/crypto/blake3
import ../crypto/slhdsa
import ../package/[errors, lgx, manifest, records, resolver, trustdoc]
import ./[spool, vcache]

export results, blake3, spool, vcache

const DecodeTurnUnits* = 1024
  ## [IMPL; G447] the dependency entries and contracts the module thread decodes from one
  ## judgment in one turn: about 1 to 2 ms of contracts under orc (the Mac, `-d:release`)

type
  WireDependency* = object
    package*: string
    kind*: RequirementKind
    version*: string
    contracts*: seq[string] ## each a deterministic encoding

  WireOpened* = object
    ## [G447] `vcache.Opened` with no reference: the inspection's contracts encoded.
    kind*: InspectionKind
    identity*: PackageIdentity
    commitment*: ManifestCommitment
    dependencies*: seq[WireDependency]
    provides*: seq[string] ## each a deterministic encoding
    error*: PackageError ## `ikIneligible`'s
    reason*: string ## `ikUnavailable`'s
    profile*: string
    kid*: seq[byte]
    key*: PublicKey
    variant*: string

  WorkerConfig* = object
    ## [G447] What the worker takes at open: fixed for the instance's start (G399).
    spoolDir*: string
    trust*: seq[byte] ## the package trust file's accepted bytes (`PmInput.trustBytes`)
    os*: string
    architecture*: string
    abi*: string
    hasAbi*: bool
    limits*: LgxLimits
    pathRules*: PathRules

  WorkerJobKind* = enum
    wjStart
    wjAppend
    wjFinish
    wjOpen
    wjDrop
    wjQuit

  WorkerJob* = object
    kind*: WorkerJobKind
    file*: uint64 ## the spool file, by the engine's id
    name*: string ## `wjAppend` with `first`: its name in the spool directory
    first*: bool
    chunk*: string ## `wjAppend`'s piece, at most 1 MiB
    config*: WorkerConfig ## `wjStart`'s

  WorkerResultKind* = enum
    wrAppended ## a `wjAppend` is done: `failure` if a write failed
    wrDigest ## `wjFinish`: the file's digest and size, or `failure`
    wrOpened ## `wjOpen`: the judgment

  WorkerResult* = object
    kind*: WorkerResultKind
    file*: uint64
    failure*: string
    digest*: Blake3Digest
    size*: int64
    opened*: WireOpened

  WorkerState* = object
    ## The worker's side: its copy of the inputs, and the spool files it holds.
    config: WorkerConfig
    trust: TrustInput
    platform: Platform
    writing: Table[uint64, SpoolWriter]
    written: Table[uint64, string] ## finished files, by id: their paths

  Decoding* = object
    ## [G447] A `WireOpened` decoded back on the module thread, a turn at a time.
    wire: WireOpened
    opened: Opened
    dep: int ## the dependency being decoded
    added: bool ## it is added to the inspection
    contract: int ## its next contract
    provided: int ## the next provided contract
    started: bool

# The no-reference check ---------------------------------------------------------------

proc refFreeNode(t: NimNode, depth: int): bool =
  if depth > 48:
    return false # only a reference makes a type this deep
  case t.typeKind
  of ntyBool, ntyChar, ntyString, ntyEnum, ntySet, ntyInt, ntyInt8, ntyInt16, ntyInt32,
      ntyInt64, ntyFloat, ntyFloat32, ntyFloat64, ntyFloat128, ntyUInt, ntyUInt8,
      ntyUInt16, ntyUInt32, ntyUInt64, ntyRange:
    true
  of ntySequence:
    refFreeNode(t.getTypeImpl[1], depth + 1)
  of ntyArray:
    refFreeNode(t.getTypeImpl[2], depth + 1)
  of ntyDistinct:
    refFreeNode(t.getTypeImpl[0], depth + 1)
  of ntyGenericInst, ntyGenericInvocation, ntyGenericBody, ntyGenericParam:
    let impl = t.getTypeImpl
    if impl.kind in {nnkObjectTy, nnkTupleTy, nnkBracketExpr, nnkDistinctTy}:
      refFreeNode(impl, depth + 1)
    else:
      false
  of ntyObject, ntyTuple:
    var impl = t.getTypeImpl
    proc fields(n: NimNode, depth: int): bool =
      case n.kind
      of nnkRecList, nnkTupleTy, nnkTupleConstr:
        for c in n:
          if not fields(c, depth):
            return false
        true
      of nnkRecCase:
        if not fields(n[0], depth):
          return false
        for i in 1 ..< n.len:
          if not fields(n[i][^1], depth):
            return false
        true
      of nnkIdentDefs:
        refFreeNode(n[^2], depth + 1)
      of nnkSym:
        refFreeNode(n.getTypeInst, depth + 1)
      of nnkEmpty, nnkNilLit:
        true
      of nnkRecWhen:
        false
      else:
        refFreeNode(n, depth + 1)

    case impl.kind
    of nnkObjectTy:
      if impl[1].kind == nnkOfInherit and not refFreeNode(impl[1][0], depth + 1):
        return false
      fields(impl[2], depth)
    of nnkTupleTy, nnkTupleConstr:
      fields(impl, depth)
    else:
      false
  else:
    # ref, ptr, pointer, proc (a closure included), cstring, var, openArray and the rest
    false

macro refFree*(T: typedesc): bool =
  ## [G447] Whether `T` holds no `ref`, `ptr`, `pointer`, closure or `cstring` at any depth:
  ## strings, seqs, arrays, sets, enums, numbers, objects and tuples of them only. It errs
  ## on the safe side: a generic object other than `seq` and `array` (`Opt`, `Result`)
  ## reads as not ref-free, so the job types spell such fields out (`abi`, `hasAbi`).
  newLit(refFreeNode(T.getTypeInst[1], 0))

template requireRefFree*(T: typedesc) =
  ## [G447] A compile-time error unless `T` is `refFree`.
  static:
    doAssert refFree(T), $T & " holds a reference and may not cross threads (G447)"

requireRefFree(WorkerJob)
requireRefFree(WorkerResult)

# Inspections, encoded and decoded ------------------------------------------------------

func asText(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

proc toWire*(o: sink Opened): WireOpened =
  ## [G447] The worker's side: each contract to its deterministic encoding.
  result = WireOpened(
    kind: o.inspection.kind,
    profile: move o.profile,
    kid: move o.kid,
    key: o.key,
    variant: move o.variant,
  )
  case o.inspection.kind
  of ikEligible:
    result.identity = o.inspection.identity
    result.commitment = o.inspection.commitment
    for d in o.inspection.dependencies:
      var w = WireDependency(package: d.package, kind: d.kind, version: d.version)
      for c in d.contracts:
        w.contracts.add(asText(encodeCbor(c)))
      result.dependencies.add(w)
    for c in o.inspection.provides:
      result.provides.add(asText(encodeCbor(c)))
  of ikIneligible:
    result.error = o.inspection.error
  of ikUnavailable:
    result.reason = o.inspection.reason

func estimatedBytes*(w: WireOpened): int =
  ## [G447; Fable's condition 6] `vcache.estimatedBytes` of the inspection `w` decodes to, by
  ## the lengths it carries: a contract's `bytes` in the walk is its encoded size, which is its
  ## encoding's length here, so nothing is walked or encoded. Taken before the decoding, which
  ## consumes `w`.
  case w.kind
  of ikEligible:
    result = unitBytes(iuRecord) + w.identity.package.len + w.identity.version.len
    for d in w.dependencies:
      result += unitBytes(iuDependency) + d.package.len + d.version.len
      for c in d.contracts:
        result += unitBytes(iuDependencyContract) + c.len
    for c in w.provides:
      result += unitBytes(iuProvided) + c.len
  of ikIneligible:
    result = unitBytes(iuRecord) + w.error.msg.len
  of ikUnavailable:
    result = unitBytes(iuRecord) + w.reason.len

func units*(w: WireOpened): int =
  ## [G477] The dependency entries and contracts `w` carries: what its decoding costs.
  result = w.dependencies.len + w.provides.len
  for d in w.dependencies:
    result += d.contracts.len

proc initDecoding*(w: sink WireOpened): Decoding =
  Decoding(wire: w)

proc decodeSome*(d: var Decoding, budget: var int): bool =
  ## [G447] Decodes dependency entries and contracts while `budget` lasts, one from it for
  ## each; true once the whole judgment is decoded (`take`).
  if not d.started:
    d.started = true
    d.opened = Opened(
      profile: d.wire.profile, kid: d.wire.kid, key: d.wire.key, variant: d.wire.variant
    )
    case d.wire.kind
    of ikEligible:
      d.opened.inspection = Inspection(
        kind: ikEligible, identity: d.wire.identity, commitment: d.wire.commitment
      )
    of ikIneligible:
      d.opened.inspection = Inspection(kind: ikIneligible, error: d.wire.error)
      return true
    of ikUnavailable:
      d.opened.inspection = Inspection(kind: ikUnavailable, reason: d.wire.reason)
      return true
  template one(bytes: string, into: untyped) =
    # [G447; Fable's D1 condition 2] The bytes are the worker's own encoding of values the
    # reader checked: one that does not decode is a fault in this process, not the archive's.
    let v = decodeCbor(bytes.toOpenArrayByte(0, bytes.high))
    if v.isErr:
      raiseAssert "a contract in the worker's answer is not deterministic CBOR"
    into.add(v.get)
    dec budget

  while d.dep < d.wire.dependencies.len:
    template w(): untyped =
      d.wire.dependencies[d.dep]

    if not d.added:
      if budget <= 0:
        return false
      d.opened.inspection.dependencies.add(
        PackageDependency(package: w.package, kind: w.kind, version: w.version)
      )
      d.added = true
      dec budget
    while d.contract < w.contracts.len:
      if budget <= 0:
        return false
      one(w.contracts[d.contract], d.opened.inspection.dependencies[d.dep].contracts)
      inc d.contract
    w.contracts.setLen(0)
    d.contract = 0
    d.added = false
    inc d.dep
  while d.provided < d.wire.provides.len:
    if budget <= 0:
      return false
    one(d.wire.provides[d.provided], d.opened.inspection.provides)
    inc d.provided
  true

proc take*(d: var Decoding): Opened =
  ## The decoded judgment, once `decodeSome` gave true.
  move d.opened

proc releaseSome*(d: var Decoding, budget: var int): bool =
  ## [G447; Fable's D1 condition 5] Frees a judgment dropped while it was decoded (its operation
  ## is gone), one decoded contract or dependency entry, then one encoded one, for each unit of
  ## `budget`, as a cancelled run's holdings are freed (G455); true once nothing is left.
  template drop(s: untyped) =
    while s.len > 0:
      if budget <= 0:
        return false
      s.setLen(s.len - 1)
      dec budget

  if d.started and d.opened.inspection.kind == ikEligible:
    drop(d.opened.inspection.provides)
    while d.opened.inspection.dependencies.len > 0:
      drop(d.opened.inspection.dependencies[^1].contracts)
      if budget <= 0:
        return false
      d.opened.inspection.dependencies.setLen(d.opened.inspection.dependencies.len - 1)
      dec budget
  drop(d.wire.provides)
  while d.wire.dependencies.len > 0:
    drop(d.wire.dependencies[^1].contracts)
    if budget <= 0:
      return false
    d.wire.dependencies.setLen(d.wire.dependencies.len - 1)
    dec budget
  true

# Running a job -------------------------------------------------------------------------

func workerConfig*(
    spoolDir: string,
    trust: seq[byte],
    platform: Platform,
    limits: LgxLimits,
    pathRules: PathRules,
): WorkerConfig =
  WorkerConfig(
    spoolDir: spoolDir,
    trust: trust,
    os: platform.os,
    architecture: platform.architecture,
    abi: platform.abi.get(""),
    hasAbi: platform.abi.isSome,
    limits: limits,
    pathRules: pathRules,
  )

proc start(w: var WorkerState, c: sink WorkerConfig) =
  w.config = c
  w.platform = Platform(os: w.config.os, architecture: w.config.architecture)
  if w.config.hasAbi:
    w.platform.abi = Opt.some(w.config.abi)
  # [G447; Fable's D2 condition 2] The module thread decoded and accepted these same bytes
  # before the worker started (`input.decodePmInput`), so the start has no outcome but
  # success short of a fault in this process.
  let file = decodeTrust(w.config.trust).valueOr:
    raiseAssert "the worker's copy of the accepted trust input is refused: " & error
  w.trust = acceptedSigning(file).valueOr:
    raiseAssert "the worker's copy of the accepted trust input is refused: " & error

proc runJob*(
    w: var WorkerState, job: sink WorkerJob, stop: LgxStop
): Opt[WorkerResult] =
  ## [G447] One job, as the worker runs it; `wjStart`, `wjDrop` and `wjQuit` answer nothing.
  case job.kind
  of wjStart:
    w.start(move job.config)
  of wjAppend:
    if job.first:
      w.writing[job.file] = createSpool(w.config.spoolDir, job.name)
    var failure = "the spool file is not open"
    w.writing.withValue(job.file, f):
      f[].append(job.chunk.toOpenArrayByte(0, job.chunk.high))
      failure = f[].failure
    return Opt.some(WorkerResult(kind: wrAppended, file: job.file, failure: failure))
  of wjFinish:
    var f: SpoolWriter
    if not w.writing.pop(job.file, f):
      return Opt.some(
        WorkerResult(
          kind: wrDigest, file: job.file, failure: "the spool file is not open"
        )
      )
    let digest = f.finish()
    if f.failure.len > 0:
      discard removeSpool(f.path)
      return Opt.some(WorkerResult(kind: wrDigest, file: job.file, failure: f.failure))
    w.written[job.file] = f.path
    return Opt.some(
      WorkerResult(kind: wrDigest, file: job.file, digest: digest, size: f.size)
    )
  of wjOpen:
    let path = w.written.getOrDefault(job.file)
    let opened =
      if path.len == 0:
        Opened(
          inspection: Inspection(kind: ikUnavailable, reason: "the spool file is gone")
        )
      else:
        judge(
          fileSource(path),
          w.trust,
          w.platform,
          w.config.limits,
          w.config.pathRules,
          stop,
        )
    return
      Opt.some(WorkerResult(kind: wrOpened, file: job.file, opened: toWire(opened)))
  of wjDrop:
    var f: SpoolWriter
    if w.writing.pop(job.file, f):
      discard f.abandon()
    var path: string
    if w.written.pop(job.file, path):
      discard removeSpool(path)
  of wjQuit:
    discard
  Opt.none(WorkerResult)

proc close*(w: var WorkerState) =
  ## At the worker's end: every spool file still held is deleted.
  for _, f in w.writing.mpairs:
    discard f.abandon()
  w.writing.clear()
  for _, path in w.written:
    discard removeSpool(path)
  w.written.clear()

{.pop.}
