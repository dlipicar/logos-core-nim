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
## - **The store's jobs** (5-5-4; Fable's check of the store's thread, design A): after
##   the start the worker holds the store's file half (`store.StoreFiles`, sent in
##   `wjStart`), its index entries the only copy. `wjStage` judges a kept spool file
##   again under the worker's trust copy, compares what the module thread sent (identity,
##   commitment, signer, variant), and writes the record's directory; its answer carries
##   what the module thread lacks: each selected module declaration's encoding, the
##   artifacts and the manifest's dependencies (D1's form), and, for the root, the
##   `{installed}` response encoded. `wjStageSigner`, `wjAbandon`, `wjCommit`,
##   `wjCollect` and `wjReply` (a committed record's `{installed}` response, read from
##   its directory) complete the set. `wjOpen` for an inspection's root candidate also
##   encodes the `{inspection}` response, so the module thread decodes no manifest.
## - **Reads below a record** (5-5-4): `wjRetained` hashes an installed record's
##   artifacts against their signed digests for a resolution's `need retained` (G448),
##   and `wjHandoff` builds a selected module's `{handoff}` response from the record's
##   directory (G451), for a query that takes no slot.

{.push raises: [].}

import std/[macros, tables]
import results
import logos_sdk/cbor
import logos_sdk/base/testhooks
import logos_sdk/crypto/blake3
import ../crypto/slhdsa
import ../package/[errors, lgx, manifest, records, resolver, trustdoc]
import ./[installed, responses, spool, vcache]

when defined(posix):
  import ./store
  export store

export results, blake3, spool, vcache

testHooksMarker("pm_jobs")

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
    when defined(posix):
      store*: StoreFiles ## [5-5-4] the store's file half, the worker's from `wjStart`
      hasStore*: bool

  WorkerJobKind* = enum
    wjStart
    wjAppend
    wjFinish
    wjOpen
    wjDrop
    wjRetained ## [G448] hash an installed record's artifacts
    wjStage ## [5-5-4] a kept spool file's record directory, written and synced
    wjStageSigner ## [5-5-4] a committed record's next generation with another signer
    wjAbandon ## [5-5-4] delete what a staging wrote; nothing names it
    wjCommit ## [5-5-4] one replacement of the index
    wjCollect ## [R1] delete retired items
    wjReply ## [5-5-4] a committed record's `{installed}` response
    wjHandoff ## [5-5-4; SPEC PM §12] a selected module's `{handoff}` response
    wjQuit

  WorkerJob* = object
    kind*: WorkerJobKind
    file*: uint64 ## the spool file, by the engine's id
    name*: string ## `wjAppend` with `first`: its name in the spool directory
    first*: bool
    chunk*: string ## `wjAppend`'s piece, at most 1 MiB
    config*: WorkerConfig ## `wjStart`'s
    request*: uint64 ## `wjRetained`'s operation
    record*: int
      ## `wjRetained`'s installed record, by its index in the operation's input
    base*: string ## `wjRetained`: the record's `a/` directory
    identity*: PackageIdentity ## `wjRetained`: the record's, for the message
    artifacts*: seq[InstalledArtifact] ## `wjRetained`: what to hash
    source*: string
      ## `wjStage`'s record source, `wjOpen`'s for an inspect record: a `package_source`'s
      ## deterministic encoding (`sourceBytes`), since `PackageSource` holds `Opt`s
    edges*: seq[ResolvedDependency] ## `wjStage`'s recorded edges
    rid*: string
      ## `wjStage` (the new directory), `wjStageSigner`, `wjAbandon`, `wjReply`
    generation*: uint64
      ## `wjStageSigner` and `wjReply`: the committed one; `wjAbandon`'s
    newDir*: bool ## `wjAbandon`: a whole directory
    commitment*: ManifestCommitment ## `wjStage`: the judged one
    signer*: PackageSigner ## `wjStage`: the judged one; `wjStageSigner`: the new one
    variant*: string ## `wjStage`: the judged variant's id
    digest*: Blake3Digest ## `wjStage`: the archive's, for the record file
    reply*: bool ## `wjStage`, `wjStageSigner`: encode the `{installed}` response
    add*: seq[IndexEntry] ## `wjCommit`
    drop*: seq[string] ## `wjCommit`: rids
    rootPackage*: string
      ## `wjOpen`: an inspection's root package name; an eligible archive of it encodes its
      ## `{inspection}` response
    rootSource*: bool ## `wjOpen`: the archive is an inspection's root source
    items*: seq[RetiredItem] ## `wjCollect`
    inspect*: bool ## `wjReply`: the `{inspection}` response instead
    module*: string ## `wjHandoff`'s

  WorkerResultKind* = enum
    wrAppended ## a `wjAppend` is done: `failure` if a write failed
    wrDigest ## `wjFinish`: the file's digest and size, or `failure`
    wrOpened ## `wjOpen`: the judgment
    wrRetained ## `wjRetained`: `failure` says what is absent or altered; empty: intact
    wrStaged ## `wjStage`, `wjStageSigner`: staged, or `fault`
    wrCommitted ## `wjCommit`: the new sequence and what it retired, or `fault`
    wrCollected ## `wjCollect`
    wrReply ## `wjReply`: the response, or `fault`

  WorkerResult* = object
    kind*: WorkerResultKind
    file*: uint64
    request*: uint64 ## `wrRetained`'s
    record*: int ## `wrRetained`'s
    failure*: string
    digest*: Blake3Digest
    size*: int64
    opened*: WireOpened
    rid*: string ## `wrStaged`
    generation*: uint64 ## `wrStaged`: the staged generation
    sequence*: uint64 ## `wrCommitted`
    modules*: seq[string]
      ## `wrStaged` of a new record: each selected module declaration's encoding, in
      ## manifest order
    artifacts*: seq[InstalledArtifact] ## `wrStaged` of a new record
    dependencies*: seq[WireDependency] ## `wrStaged` of a new record: its manifest's
    reply*: string
      ## an encoded §15 response: `wrStaged`'s or `wrReply`'s `{installed}`, `wrOpened`'s
      ## `{inspection}` for an inspection's root candidate
    hasFault*: bool
    fault*: StoreFault ## with `hasFault`; `failure` holds the detail
    faultIdentity*: PackageIdentity ## with `hasFaultIdentity`
    hasFaultIdentity*: bool
    retired*: seq[RetiredItem] ## `wrCommitted`
    collected*: Collected ## `wrCollected`
    base*: string ## `wrStaged`: the record's `a/` directory

  WorkerState* = object
    ## The worker's side: its copy of the inputs, and the spool files it holds.
    config: WorkerConfig
    trust: TrustInput
    platform: Platform
    writing: Table[uint64, SpoolWriter]
    written: Table[uint64, string] ## finished files, by id: their paths
    when defined(posix):
      store: StoreFiles
      storeHeld: bool ## `store` came in `wjStart`
    when defined(lcnTestHooks):
      failStage*: string
        ## a test's: staging this package fails as a full disk would (`ENOSPC`)

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

func sourceBytes*(s: PackageSource): string =
  ## [G447] A source crossing to the worker: its deterministic encoding.
  asText(encodeCbor(s.toCbor))

func sourceOf(bytes: string): PackageSource =
  ## The worker's side; the bytes are the module thread's own encoding.
  let v = decodeCbor(bytes)
  doAssert v.isOk, "the module thread's encoding of a source"
  let s = decodeSource(v.get)
  doAssert s.isOk, "the module thread's encoding of a source"
  s.get

func toWire*(d: PackageDependency): WireDependency =
  result = WireDependency(package: d.package, kind: d.kind, version: d.version)
  for c in d.contracts:
    result.contracts.add(asText(encodeCbor(c)))

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
      result.dependencies.add(d.toWire)
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
  when defined(posix):
    if w.config.hasStore:
      w.store = move w.config.store
      w.config.hasStore = false
      w.storeHeld = true

when defined(posix):
  proc faulted(r: var WorkerResult, e: StoreError) =
    r.hasFault = true
    r.fault = e.fault
    r.failure = e.detail
    if e.identity.isSome:
      r.faultIdentity = e.identity.get
      r.hasFaultIdentity = true

  proc stageJob(w: var WorkerState, job: WorkerJob, stop: LgxStop): WorkerResult =
    ## [5-5-4; Fable's check §2] The kept spool file judged again under the worker's trust
    ## copy and platform, its facts compared with what the module thread sent, then staged.
    result = WorkerResult(
      kind: wrStaged, request: job.request, file: job.file, rid: job.rid, generation: 1
    )
    let id = Opt.some(job.identity)
    let path = w.written.getOrDefault(job.file)
    if path.len == 0:
      result.faulted(
        StoreError(fault: sfSource, identity: id, detail: "the spool file is gone")
      )
      return
    let (o, held) = judgePackage(
      fileSource(path), w.trust, w.platform, w.config.limits, w.config.pathRules, stop
    )
    if held.isNone:
      let why =
        case o.inspection.kind
        of ikUnavailable:
          o.inspection.reason
        of ikIneligible:
          $o.inspection.error.code & ": " & o.inspection.error.msg
        of ikEligible:
          ""
      result.faulted(
        StoreError(fault: sfSource, identity: id, detail: "judged again: " & why)
      )
      return
    let p = held.get
    let v = p.verified
    if v.manifest.identity != job.identity or v.commitment != job.commitment or
        v.packageSigner != job.signer or p.variant.id != job.variant:
      result.faulted(
        StoreError(
          fault: sfSource,
          identity: id,
          detail: "judged again, the archive no longer gives the judged package",
        )
      )
      return
    when defined(lcnTestHooks):
      if w.failStage.len > 0 and job.identity.package == w.failStage:
        result.faulted(
          StoreError(
            fault: sfWrite,
            identity: id,
            detail: w.store.root & ": No space left on device (test hook)",
          )
        )
        return
    let record = installedRecord(p, sourceOf(job.source), job.edges)
    let st = w.store.stageFiles(p, fileSource(path), record, job.rid, job.digest, stop)
    if st.isErr:
      result.faulted(st.error)
      return
    result.base = st.get.base
    for m in record.modules:
      result.modules.add(asText(encodeCbor(m.value)))
    result.artifacts = record.artifacts
    for d in v.manifest.dependencies:
      result.dependencies.add(d.toWire)
    if job.reply:
      result.reply = asText(encodeCbor(installedResult(record, st.get.base)))

  when defined(lcnTestHooks):
    proc setCrashAt*(w: var WorkerState, at: CrashPoint) =
      ## A test's crash point on the worker's store half.
      w.store.crashAt = at

  proc storeJob(w: var WorkerState, job: WorkerJob, stop: LgxStop): Opt[WorkerResult] =
    ## [5-5-4] The jobs on the store's file half.
    if not w.storeHeld:
      # A worker started without the installed state (the engine's tests): every store
      # job is refused, and nothing is written.
      if job.kind == wjAbandon:
        return
      var r = WorkerResult(
        kind:
          case job.kind
          of wjStage, wjStageSigner: wrStaged
          of wjCommit: wrCommitted
          of wjCollect: wrCollected
          else: wrReply
        ,
        request: job.request,
        file: job.file,
        rid: job.rid,
      )
      r.faulted(
        StoreError(fault: sfDamaged, detail: "the worker holds no installed state")
      )
      return Opt.some(r)
    case job.kind
    of wjStage:
      return Opt.some(w.stageJob(job, stop))
    of wjStageSigner:
      var r = WorkerResult(kind: wrStaged, request: job.request, rid: job.rid)
      let st = w.store.stageSignerFiles(
        job.rid, job.generation, job.identity, job.signer, stop
      )
      if st.isErr:
        r.faulted(st.error)
      else:
        r.generation = st.get.file.generation
        if job.reply:
          r.reply = asText(encodeCbor(installedResult(st.get.file.record, st.get.base)))
      return Opt.some(r)
    of wjAbandon:
      discard w.store.abandonFiles(job.rid, job.generation, job.newDir)
    of wjCommit:
      var r = WorkerResult(kind: wrCommitted, request: job.request)
      let c = w.store.commitFiles(job.add, job.drop)
      if c.isErr:
        r.faulted(c.error)
      else:
        r.sequence = c.get.sequence
        r.retired = c.get.retired
      return Opt.some(r)
    of wjCollect:
      return Opt.some(
        WorkerResult(kind: wrCollected, collected: w.store.collectFiles(job.items))
      )
    of wjHandoff:
      # [SPEC PM §12; G451] Built from the record's directory, its manifest read there
      # (Fable's check §1.3), under the worker's trust copy. A refusal with a package
      # error is the response; its detail is for the operator's log (`failure`).
      var r = WorkerResult(kind: wrReply, request: job.request)
      let read = readRecordFiles(
        w.store.root,
        IndexEntry(rid: job.rid, generation: job.generation, identity: job.identity),
      )
      if read.isErr:
        r.faulted(read.error)
        return Opt.some(r)
      let (m, f) = read.get
      let base = baseOf(w.store.root, job.rid)
      let held = Installed(rid: job.rid, file: f, manifest: m, base: base)
      let h = buildHandoff(
        f.record, base, m, f.record.commitment, job.module, w.trust, held.reader
      )
      if h.isOk:
        r.reply = asText(encodeCbor(handoffResult(h.get)))
      else:
        let code = h.error.refusal.code
        r.failure = h.error.detail
        if code.isSome:
          r.reply = asText(encodeCbor(errorResult(code.get, h.error.msg)))
        else:
          r.faulted(
            StoreError(
              fault: sfDamaged,
              identity: Opt.some(job.identity),
              detail: h.error.msg & ": " & h.error.detail,
            )
          )
      return Opt.some(r)
    of wjReply:
      var r = WorkerResult(kind: wrReply, request: job.request)
      let read = readRecordFiles(
        w.store.root,
        IndexEntry(rid: job.rid, generation: job.generation, identity: job.identity),
      )
      if read.isErr:
        r.faulted(read.error)
      else:
        r.reply = asText(
          encodeCbor(installedResult(read.get[1].record, baseOf(w.store.root, job.rid)))
        )
      return Opt.some(r)
    else:
      raiseAssert "not a store job"
    Opt.none(WorkerResult)

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
    var reply: string
    let opened =
      if path.len == 0:
        Opened(
          inspection: Inspection(kind: ikUnavailable, reason: "the spool file is gone")
        )
      else:
        let (o, held) = judgePackage(
          fileSource(path),
          w.trust,
          w.platform,
          w.config.limits,
          w.config.pathRules,
          stop,
        )
        if held.isSome and (
          job.rootSource or
          held.get.verified.manifest.identity.package == job.rootPackage
        ):
          # [5-5-4; Fable's check §3] an inspection's root candidate: its response is
          # encoded here, so the module thread decodes no manifest for it.
          reply = asText(
            encodeCbor(
              inspectionResult(inspectRecord(held.get.verified, sourceOf(job.source)))
            )
          )
        o
    return Opt.some(
      WorkerResult(kind: wrOpened, file: job.file, opened: toWire(opened), reply: reply)
    )
  of wjDrop:
    var f: SpoolWriter
    if w.writing.pop(job.file, f):
      discard f.abandon()
    var path: string
    if w.written.pop(job.file, path):
      discard removeSpool(path)
  of wjRetained:
    # [G448] Hashed at each use (Q6 (a)); the run memoizes the answer for its operation.
    let failure =
      when defined(posix):
        let r = checkRetainedFiles(job.base, job.identity, job.artifacts, stop)
        if r.isErr: r.error.detail else: ""
      else:
        "the installed state is POSIX only"
    return Opt.some(
      WorkerResult(
        kind: wrRetained, request: job.request, record: job.record, failure: failure
      )
    )
  of wjStage, wjStageSigner, wjAbandon, wjCommit, wjCollect, wjReply, wjHandoff:
    when defined(posix):
      return w.storeJob(job, stop)
    else:
      raiseAssert "the installed state is POSIX only"
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
  when defined(posix):
    if w.storeHeld:
      w.store.close()
      w.storeHeld = false

{.pop.}
