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
## - **An inspection crosses as it is** (step 5-3c-4, G482): the resolver's `Inspection`
##   holds its contracts as their deterministic encodings in one buffer and no reference
##   (`requireRefFree`), so `Opened` crosses whole and the module thread decodes nothing
##   of a judgment. Before G482 it crossed encoded (D1, `WireOpened`) and was decoded
##   back in turns.
## - **The staged record's dependencies** (G447, D1): an installed record keeps its
##   manifest's dependencies as values, so `wjStage`'s answer carries them as an
##   `Inspection` of them (`eligibleInspection`), and the module thread decodes them
##   (`Decoding`), at most `DecodeTurnUnits` a turn, counted as G477's walk counts
##   them: a dependency entry and a contract are a unit each. A 4 MiB manifest holds at
##   most about 80,000 entries or about 22,000 commitments.
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
## - **The read-only worker** (5-6b-1; G500; Q10 (a)): a second worker thread runs this
##   same code with a configuration of its own (`readOnly`, the installation root's path
##   in `root`, no store files), and only two jobs: `wjPage`, one `list_installed_packages`
##   page read from the records' `m/` directories, and `wjReaderHandoff`, a reader's
##   `get_runtime_handoff` built as `wjHandoff` builds it. It makes its own trust copy
##   once, at `wjStart`, from the same accepted bytes, and shares nothing with the first
##   worker. Reading by path is sound while the engine holds the snapshot the job reads
##   (G451's R1): no collect deletes what a held snapshot names.

{.push raises: [].}

import std/[atomics, macros, tables]
import results
import logos_sdk/cbor
import logos_sdk/base/testhooks
import logos_sdk/crypto/blake3
import ../crypto/slhdsa
import ../package/[errors, lgx, manifest, records, reffree, resolver, trustdoc]
import ./[installed, responses, spool, vcache]

when defined(posix):
  import ./store
  export store

when defined(lcnTestHooks):
  import std/[os, strutils]

export results, blake3, reffree, spool, vcache

testHooksMarker("pm_jobs")

const DecodeTurnUnits* = 1024
  ## [IMPL; G447] the dependency entries and contracts the module thread decodes from a
  ## staged record's dependencies in one turn (`Decoding`), or frees from a dropped
  ## judgment's entries (G482): about 1 to 2 ms of contracts under orc (the Mac,
  ## `-d:release`)

type
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
    readOnly*: bool ## [5-6b-1; G500] the read-only worker: `wjPage`, `wjReaderHandoff`
    root*: string ## [G500] the read-only worker's: the installation root (`install/`)

  PageEntry* = object ## [G500] One record a page job reads: what the index names it by.
    rid*: string
    generation*: uint64
    identity*: PackageIdentity

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
    wjPage ## [5-6b-1; G500] the read-only worker's `list_installed_packages` page
    wjReaderHandoff ## [5-6b-1; G500, ruling A] a reader's `get_runtime_handoff`
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
    module*: string ## `wjHandoff`'s and `wjReaderHandoff`'s
    page*: seq[PageEntry] ## `wjPage`'s candidates, in listing order, at most `limit`
    budget*: int ## `wjPage`: the page's byte budget (`listing.fits`)

  WorkerResultKind* = enum
    wrAppended ## a `wjAppend` is done: `failure` if a write failed
    wrDigest ## `wjFinish`: the file's digest and size, or `failure`
    wrOpened ## `wjOpen`: the judgment
    wrRetained ## `wjRetained`: `failure` says what is absent or altered; empty: intact
    wrStaged ## `wjStage`, `wjStageSigner`: staged, or `fault`
    wrCommitted ## `wjCommit`: the new sequence and what it retired, or `fault`
    wrCollected ## `wjCollect`
    wrReply ## `wjReply`: the response, or `fault`; also `wjHandoff`, `wjReaderHandoff`
    wrPage ## [G500] `wjPage`: `count` record values encoded back to back, or `fault`

  WorkerResult* = object
    kind*: WorkerResultKind
    file*: uint64
    request*: uint64 ## `wrRetained`'s
    record*: int ## `wrRetained`'s
    failure*: string
    digest*: Blake3Digest
    size*: int64
    opened*: Opened ## [G482] crosses as it is: it holds no reference
    rid*: string ## `wrStaged`
    generation*: uint64 ## `wrStaged`: the staged generation
    sequence*: uint64 ## `wrCommitted`
    modules*: seq[string]
      ## `wrStaged` of a new record: each selected module declaration's encoding, in
      ## manifest order
    artifacts*: seq[InstalledArtifact] ## `wrStaged` of a new record
    staged*: Inspection
      ## `wrStaged` of a new record: its manifest's dependencies, as an inspection holds
      ## them (`eligibleInspection`, G482), for `Decoding`
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
    count*: int ## `wrPage`: the records in `reply`

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
    ## [G447, G482] A staged record's dependencies decoded to values on the module thread,
    ## a turn at a time: an installed record keeps values.
    staged: Inspection
    deps: seq[PackageDependency]
    dep: int ## the dependency being decoded
    added: bool ## it is added to `deps`
    listed: int ## its contracts decoded
    next: int ## the next contract in `staged`

# The no-reference check (`reffree.nim`) -----------------------------------------------

requireRefFree(WorkerJob)
requireRefFree(WorkerResult)

# The staged record's dependencies, decoded ---------------------------------------------

func asText*(b: openArray[byte]): string =
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

proc initDecoding*(staged: sink Inspection): Decoding =
  ## `staged`: an eligible inspection of the manifest's dependencies (`wrStaged`).
  Decoding(staged: staged)

proc decodeSome*(d: var Decoding, budget: var int): bool =
  ## [G447] Decodes dependency entries and contracts while `budget` lasts, one from it for
  ## each; true once every entry is decoded (`take`).
  while d.dep < d.staged.dependencies.len:
    template w(): untyped =
      d.staged.dependencies[d.dep]

    if not d.added:
      if budget <= 0:
        return false
      d.deps.add(
        PackageDependency(package: w.package, kind: w.kind, version: w.version)
      )
      d.added = true
      dec budget
    while d.listed < w.listedCount:
      if budget <= 0:
        return false
      # [G447; Fable's D1 condition 2] The bytes are the worker's own encoding of values the
      # reader checked: one that does not decode is a fault in this process, not the
      # archive's.
      let at = d.staged.contractAt(d.next)
      let v = decodeCbor(d.staged.contractData.toOpenArrayByte(at.a, at.b))
      if v.isErr:
        raiseAssert "a contract in the worker's answer is not deterministic CBOR"
      d.deps[d.dep].contracts.add(v.get)
      dec budget
      inc d.listed
      inc d.next
    d.listed = 0
    d.added = false
    inc d.dep
  true

proc take*(d: var Decoding): seq[PackageDependency] =
  ## The decoded dependencies, once `decodeSome` gave true. The encodings go with it.
  d.staged = Inspection(kind: ikUnavailable)
  move d.deps

proc releaseSome*(deps: var seq[InspectedDependency], budget: var int): bool =
  ## [G447, G482; Fable's D1 condition 5] Frees a dropped judgment's dependency entries (its
  ## operation is gone), one for each unit of `budget`, as a cancelled run's holdings are
  ## freed (G455); true once none is left. Its encodings went at once: two blocks.
  while deps.len > 0:
    if budget <= 0:
      return false
    deps.setLen(deps.len - 1)
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
    result.staged =
      eligibleInspection(v.manifest.identity, v.commitment, v.manifest.dependencies, [])
    if job.reply:
      result.reply = asText(encodeCbor(installedResult(record, st.get.base)))

  when defined(lcnTestHooks):
    # [IMPL] A hosted test's pause before each record a page job reads, in milliseconds
    # (0: none), so that a suite can hold page jobs in flight (5-6b-1;
    # `test_pm_queries`). Read once, when the library is loaded.
    let pagePaceMs =
      try:
        parseInt(getEnv("LCN_TEST_PM_PAGE_PACE_MS", "0"))
      except ValueError:
        0

  proc handoffJob(w: WorkerState, root: string, job: WorkerJob): WorkerResult =
    ## [SPEC PM §12; G451] Built from the record's directory, its manifest read there
    ## (Fable's check §1.3), under the worker's trust copy. A refusal with a package
    ## error is the response; its detail is for the operator's log (`failure`). The
    ## first worker's `wjHandoff` and the read-only worker's `wjReaderHandoff` (G500)
    ## both run it, so a reader gets the bytes the binding gets.
    result = WorkerResult(kind: wrReply, request: job.request)
    let read = readRecordFiles(
      root, IndexEntry(rid: job.rid, generation: job.generation, identity: job.identity)
    )
    if read.isErr:
      result.faulted(read.error)
      return
    let (m, f) = read.get
    let base = baseOf(root, job.rid)
    let held = Installed(rid: job.rid, file: f, manifest: m, base: base)
    let h = buildHandoff(
      f.record, base, m, f.record.commitment, job.module, w.trust, held.reader
    )
    if h.isOk:
      result.reply = asText(encodeCbor(handoffResult(h.get)))
    else:
      let code = h.error.refusal.code
      result.failure = h.error.detail
      if code.isSome:
        result.reply = asText(encodeCbor(errorResult(code.get, h.error.msg)))
      else:
        result.faulted(
          StoreError(
            fault: sfDamaged,
            identity: Opt.some(job.identity),
            detail: h.error.msg & ": " & h.error.detail,
          )
        )

  proc pageJob(w: WorkerState, job: WorkerJob, stop: LgxStop): WorkerResult =
    ## [5-6b-1; G500] One `list_installed_packages` page: each candidate's record read
    ## from its `m/` and encoded as `installed_package_record`, in order, until the
    ## page's byte budget or the candidates end; at least one record.
    result = WorkerResult(kind: wrPage, request: job.request)
    var items: seq[byte]
    for p in job.page:
      if not stop.isNil and stop[].load(moRelaxed):
        break
      when defined(lcnTestHooks):
        if pagePaceMs > 0:
          sleep(pagePaceMs)
      let read = readRecordFiles(
        w.config.root,
        IndexEntry(rid: p.rid, generation: p.generation, identity: p.identity),
      )
      if read.isErr:
        result.faulted(read.error)
        return
      let bytes =
        encodeCbor(recordValue(read.get[1].record, baseOf(w.config.root, p.rid)))
      if result.count > 0 and items.len + bytes.len > job.budget:
        break
      items.add(bytes)
      inc result.count
    result.reply = asText(items)

  proc readJob(w: var WorkerState, job: WorkerJob, stop: LgxStop): WorkerResult =
    ## [5-6b-1; G500] The read-only worker's jobs, below `config.root`.
    doAssert w.config.readOnly, "a read job on the first worker"
    case job.kind
    of wjPage:
      w.pageJob(job, stop)
    of wjReaderHandoff:
      w.handoffJob(w.config.root, job)
    else:
      raiseAssert "not a read job"

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
      return Opt.some(w.handoffJob(w.store.root, job))
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
      WorkerResult(kind: wrOpened, file: job.file, opened: opened, reply: reply)
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
  of wjPage, wjReaderHandoff:
    when defined(posix):
      return Opt.some(w.readJob(job, stop))
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
