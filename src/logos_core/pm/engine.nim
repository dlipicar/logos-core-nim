## The Package Manager's engine (Tier 5 step 5-3b; DECISIONS G401, G402, G405;
## docs/PACKAGE-MANAGER.md §3, §4). It owns the checked input, the catalog
## state, the bindings and their routes, the verification cache and the
## resolution drivers, and does no I/O: each entry point returns the
## `Command`s to carry out, and their results come back as `Event`s. The shell
## (`pm/shell.nim`, 5-3b-2) carries them out over the kit: routes through
## Runtime Control, calls on `lcn.storage_fetch`, timers and the state file.
##
## **Routes** (G402). At `start`, every binding gets a route to its provider
## instance:
## - **every establishment has a new key** from the injected source: a replay
##   returns the retained result and revives nothing (R l.3072-3082), so a
##   fixed key would hand a lost route's old record back. A key is reused only
##   to retry an establishment whose response was lost (R l.3077);
## - once a route is ready, its readiness is watched (`cmWatch`: subscribe to
##   `fetch_readiness_changed_event`, then call `fetch_readiness`);
## - **a lost route** (`evRouteLost`, or a call answered `akRouteLost`) is
##   renewed with a new key (`renew_route`, then `materialize`, R l.3081,
##   l.3089-3090); a renewal refused as unknown, closed, failed or revoked
##   releases the old handles and establishes anew (R l.3094-3096);
## - **a refused establishment** is retried after a bounded back-off; until
##   the route is ready the binding's material is unavailable;
## - **after `stop`** (`_MODULE_destroy` began) nothing is issued: no
##   establishment starts while the module is destroyed (G437).
##
## **Retrieval** (G402) runs one object at a time per binding, in order of
## request (`fetcher.nim`). Every call carries `read_deadline_ms` as its
## deadline, and the engine's own timer ends a call that passes it, whatever
## the provider does; a late answer is ignored.
##
## **The catalog** (G401) is acquired once its binding reports `ready`, then
## retried on each later `ready` and after a bounded back-off while the
## binding stays `ready`. One accepted or refused document ends acquisition
## for this start: the locator names fixed bytes, so reading it again gives
## the same answer (no refresh). An accepted document's kept file is written
## by `cmWriteKept`; the catalog is in use whether or not that write succeeds.
##
## **Resolution** (G405) goes through `driver.nim`: each source it needs is
## retrieved on its binding and inspected through the verification cache
## (`vcache.nim`). A source naming no binding is unavailable, and the name is
## logged once per start. With no catalog in use, an operation fails
## `package-unavailable`, never as if the catalog were empty (PM l.1308-1309).
##
## **Turns** (G455): a resolution runs one turn of work at a time. When a turn
## is spent the engine returns `cmContinue`, and the shell posts
## `evContinue` for the next turn of the event loop, so routes, timers and
## other operations go on between turns, and operations alternate turn by
## turn. `cancel` drops an operation whose caller gave it up; a continue that
## arrives for an operation that is gone is ignored (Fable F3). What a finished
## or cancelled operation's run holds is freed a turn at a time, by continues
## of their own (`ReleaseOperation`), never at once.
##
## **The worker** (5-5-3; G446, G447): an archive is never held in memory. Its
## retrieval hands each `read_object` answer to the worker (`cmWork`), which
## appends it to the archive's spool file; at most `SpoolLag` pieces are
## unwritten, then the next read waits for the worker. Once `stat_object`
## gives the size, the retrieval takes that much of the inspections' share of
## the spool (`SpoolShareArchives` × `archive_bytes`), waiting first in, first
## out while it would pass it; the first always fits. With every byte written
## the worker gives the digest: a cache hit answers at once, a miss has the
## worker judge the file (`vcache.judge`). Either way the spool file is then
## deleted and its share released. The judgment crosses as it is (G482: its
## contracts are encodings in one buffer), and is admitted to the cache and
## supplied in the turn it arrives. One whose operation went is freed: its
## encodings at once, its dependency entries `DecodeTurnUnits` at a time, a turn
## each, by continues of their own (`DecodeOperation`). A spool file that cannot
## be written ends the retrieval: the archive is unavailable and the log names
## the cause (PM l.1094). An archive whose operation is gone (cancelled,
## answered) is dropped at its next step. The catalog's retrieval is kept in
## memory, bounded by `catalog_bytes`.
##
## **The operations** (5-5-4; G448, G449; docs/PACKAGE-MANAGER.md §11):
## `inspect_package`, `install_package`, `remove_package` and `update_package`
## (`submit`), each in its slot (`slots.nim`): one mutation at a time, and one
## inspection beside it, each queue at most `MaxQueuedOperations`. An operation
## that takes its slot holds the snapshot current then (`Snapshot`, immutable,
## its records shared by every snapshot that names them) and starts its
## `operation_deadline_ms` timer. It resolves against that snapshot; the
## worker answers `need retained` by hashing the record's files (G448). An
## install stages and commits each missing package on its own, dependencies
## first and the root last; an update's last commit swaps the current root; a
## remove is one commit. Each commit gives the next snapshot. Once the last
## commit has begun (`lastCommit`), neither the deadline nor a cancel applies.
## A cancel, a deadline, or a stop ends an operation at its next step: its run
## is dropped, its call cancelled, its kept archives and uncommitted directory
## deleted, its snapshot released and its slot passed on; the worker's job
## already queued still runs, for nobody (G449's limit). What a commit stops
## naming is retired and collected on the worker once no held snapshot names
## it. Each operation's time and archive bytes go to the operator's log.
## `handoff` is a query: no slot, the snapshot held until the worker answers.

{.push raises: [], gcsafe.}

import std/[algorithm, monotimes, sets, strutils, tables]
import results
import logos_sdk/base/hex
import logos_sdk/cbor
import ../package/[errors, manifest, records, resolver]
import ./[input, catalog, fetcher, vcache, driver, jobs, slots, responses, installed]

when defined(posix):
  import ./store

export results, input, catalog, fetcher, vcache, driver, jobs, slots, responses

const
  ReleaseOperation* = 0'u64
    ## [IMPL; G455] the operation id of the continues that free finished and
    ## cancelled runs; no request has it
  DecodeOperation* = high(uint64)
    ## [IMPL; G447, G482] the operation id of the continues that free the entries of
    ## judgments whose operation went (before G482 they also decoded the worker's
    ## judgments); no request has it
  SpoolBudgetArchives* = 4
    ## [IMPL; G446; plan §4.3] a mutation's spool budget, in archives of
    ## `archive_bytes`: 4 GiB at the preset; never less than one archive
  SpoolLag* = 4
    ## [IMPL; G447] the pieces of one retrieval handed to the worker and not yet
    ## written; the next `read_object` waits while this many are
  RouteBackoffMs* = [1_000'u32, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000]
    ## [IMPL; G402] the waits before establishing again after a refusal; the
    ## last repeats
  AcquireBackoffMs* = [1_000'u32, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000]
    ## [IMPL; G401] the waits before reading the catalog again while its binding
    ## stays `ready`; the last repeats
  MaxLostResponses* = 3
    ## [IMPL; G402] an establishment or renewal whose response was lost is retried
    ## under the same key this many times, then counts as refused

type
  Readiness* = enum
    ## [SPEC STORAGE-FETCH §4] `lcn.storage_fetch.readiness`
    rdStarting = "starting"
    rdReady = "ready"
    rdOffline = "offline"

  RouteState* = enum
    rsIdle ## before `start`
    rsEstablishing
    rsReady
    rsRenewing
    rsBackoff ## an establishment was refused; another follows a back-off
    rsStopped

  KeySource* = proc(): string {.gcsafe, raises: [].}
    ## A fresh `request_key`: 128 random bits in hex in the shell, never a fixed
    ## value. An empty key counts as a refused establishment.
  Clock* = proc(): int64 {.gcsafe, raises: [].}
    ## [G449] monotonic milliseconds, for each operation's time in the operator's log

  CommandKind* = enum
    cmEstablish ## `openRoute` to `instance` for `lcn.storage_fetch` under `key`
    cmRenew ## `renew_route` on `route` under `key`, then `materialize`
    cmRelease ## release `route`'s handles
    cmWatch
      ## subscribe to `fetch_readiness_changed_event` on the binding's route, then
      ## call `fetch_readiness`; each answer is an `evReadiness`
    cmStat ## `stat_object`
    cmRead ## `read_object`
    cmTimer ## report `evTimer` after `ms`
    cmWriteKept ## replace `catalog.kept` with `kept` (sync and rename)
    cmReply ## the outcome of `resolve`'s request
    cmLog ## a line for the module's log
    cmContinue
      ## [G455] report `evContinue` for `operation` in a later turn of the
      ## event loop, never in the drain that issued it (Fable F2)
    cmWork
      ## [G447] hand `job` to the worker; its answer, if it has one, is an
      ## `evWorked`
    cmAnswer ## [G449] the outcome of `submit`'s operation
    cmCancelCall
      ## [G449] cancel the outstanding call `cancelled` through the Interface's
      ## cancel; its answer, if one still comes, is an `evAnswer`

  Command* = object
    case kind*: CommandKind
    of cmEstablish, cmRenew, cmRelease, cmWatch:
      binding*: string
      instance*: string
      route*: string ## renew and release
      key*: string ## establish and renew
    of cmStat, cmRead:
      call*: uint64
      target*: string ## the binding
      locator*: seq[byte]
      offset*: uint64
      length*: uint32
      deadlineMs*: uint32
    of cmTimer:
      timer*: uint64
      ms*: uint32
    of cmWriteKept:
      kept*: seq[byte]
    of cmReply:
      request*: uint64
      outcome*: Result[Resolution, PackageError]
    of cmLog:
      text*: string
    of cmContinue:
      operation*: uint64
    of cmWork:
      job*: WorkerJob
    of cmAnswer:
      answerTo*: uint64
      answer*: OperationAnswer
    of cmCancelCall:
      cancelled*: uint64

  RouteAnswer* = enum
    raReady
    raRefused ## refused, unknown, closed, failed or revoked
    raLost ## no response arrived

  EventKind* = enum
    evEstablished ## the answer to `cmEstablish`
    evRenewed ## the answer to `cmRenew`
    evRouteLost ## `onRouteEnd` fired for the binding's route
    evReadiness
    evAnswer ## the answer to `cmStat` or `cmRead`
    evTimer
    evContinue ## [G455] the next turn of `cmContinue`'s operation
    evWorked ## [G447] the worker's answer to a `cmWork`

  Event* = object
    case kind*: EventKind
    of evEstablished, evRenewed:
      binding*: string
      key*: string
      answer*: RouteAnswer
      route*: string ## the established route's id
      reason*: string ## foreign text, for the log
    of evRouteLost:
      lostBinding*: string
      lostRoute*: string
    of evReadiness:
      readyBinding*: string
      readiness*: Readiness
    of evAnswer:
      call*: uint64
      reply*: Answer
    of evTimer:
      timer*: uint64
    of evContinue:
      continued*: uint64
    of evWorked:
      worked*: WorkerResult

  JobWait = enum
    jwNone
    jwCall ## a call is outstanding; the timer is its deadline
    jwRoute ## waiting for the route; the timer bounds the wait
    jwReady ## waiting for `ready`; the timer bounds the wait
    jwBackoff ## the timer ends the back-off
    jwSpool ## [G447] `SpoolLag` pieces are not yet written
    jwShare ## [G446] the archive waits for its part of the inspections' share

  Job = object
    id: uint64
    catalog: bool ## the catalog document, else `source`'s archive for `request`
    request: uint64
    source: PackageSource
    fetch: Retrieval
    wait: JobWait
    call: uint64
    timer: uint64
    refetch: bool ## [G446] an evicted archive fetched again for its extraction

  Binding = object
    name: string
    instance: string
    state: RouteState
    route: string
    key: string
    lost: int ## lost responses in a row under `key`
    generation: int
      ## counts the times a route became ready, a renewal included: a renewed
      ## route keeps its id
    backoff: int ## refusals in a row
    readiness: Opt[Readiness]
    jobs: seq[Job] ## the head runs
    active: bool ## the head has started

  SpoolPhase = enum
    spWriting ## the retrieval runs
    spFinishing ## every piece is handed on; the digest is asked for
    spOpening ## the worker judges the file

  Spool = object
    ## [G446, G447] An archive's spool file, from the share's grant to its deletion. Its
    ## id is the retrieval job's.
    request: uint64
    source: PackageSource
    binding: int
    reserved: int64 ## its part of the inspections' share
    created: bool ## the first piece, which creates the file, is handed on
    unacked: int ## pieces handed to the worker and not yet written
    phase: SpoolPhase
    digest: Blake3Digest
    mutation: bool ## [G446] a mutation's: within its budget, kept once judged
    kept: bool ## judged and kept for extraction
    eligible: bool ## its inspection was eligible
    root: bool ## the operation's first eligible archive: the root's, never evicted
    judged: bool ## eligible, with the facts below: what `wjStage` compares (Fable's §2)
    identity: PackageIdentity
    commitment: ManifestCommitment
    signer: PackageSigner
    variant: string
    refetch: bool ## [G446] fetched again by digest at extraction: not judged here

  TimerKind = enum
    tkRoute ## a binding's establishment back-off
    tkJob ## a job's call deadline, wait bound or back-off
    tkAcquire ## the catalog's back-off
    tkDeadline ## [G449] an operation's `operation_deadline_ms`; `job` is its request

  TimerTarget = object
    kind: TimerKind
    binding: int
    job: uint64

  Operation = object ## [G449] One operation from `submit` to its answer.
    request: OperationRequest
    slot: SlotKind
    started: bool ## it holds its slot
    startedMs: int64
    bytes: int64 ## the archive bytes retrieved for it
    deadline: uint64 ## its deadline's timer
    snap: Snapshot ## the snapshot it holds from taking its slot
    lastCommit: bool
      ## its last commit has begun: neither the deadline nor a cancel applies (Fable's §4)
    rootKept: bool ## [G446] its root's archive is kept
    evicted: seq[Evicted]
      ## [G446] archives its budget deleted, to be fetched again by digest at extraction
    phase: MutationPhase
    queue: seq[SelectedPackage]
      ## [5-5-4] what is left to install, in dependency order (post-order), the root last
    pending: Pending
    dropRid: string ## an update's current root, dropped by the root's commit
    reply: string ## the answer's encoded response, once the worker made it
    inspections: Table[string, string]
      ## [5-5-4] an inspection's root candidates' encoded `{inspection}` responses, by
      ## identity and commitment (`judgedKey`)

  Evicted = object
    source: PackageSource
    digest: Blake3Digest
    identity: PackageIdentity
    commitment: ManifestCommitment
    signer: PackageSigner
    variant: string
    judged: bool ## eligible: the facts above hold

  MutationPhase = enum
    mpIdle
    mpStaging ## a `wjStage` or `wjStageSigner` runs
    mpDecoding ## the staged record's dependencies and modules decode, a turn at a time
    mpCommitting ## a `wjCommit` runs
    mpReplying ## a `wjReply` runs
    mpRefetching ## [G446] an evicted archive is fetched again

  Pending = object ## [5-5-4] The record an operation is staging and committing.
    selected: SelectedPackage
    signerOnly: bool ## a signer replacement of `rid`
    signer: PackageSigner
    rid: string
    generation: uint64
    root: bool ## the operation's root: its commit is the last
    base: string
    deps: Decoding
    depsDone: bool
    dependencies: seq[PackageDependency]
    modules: seq[string]
    decoded: seq[ModuleDeclaration]
    artifacts: seq[InstalledArtifact]
    file: uint64 ## its kept spool file; 0 for a signer replacement

  CommitPending = object
    ## [5-5-4] A commit the worker runs: what the snapshot becomes when it lands, kept apart
    ## from its operation so that a commit landing after a cancel still moves the snapshot.
    add: Opt[SnapRecord]
    rid: string ## the staged record, deleted if the commit fails
    generation: uint64
    newDir: bool
    drop: seq[string]
    replyAfter: Opt[SnapRecord] ## an update to an installed target answers its record

  OperationKind* = enum
    ## [SPEC PM §15] The four operations 5-5 builds (G449).
    opInspect = "inspect_package"
    opInstall = "install_package"
    opRemove = "remove_package"
    opUpdate = "update_package"

  OperationRequest* = object
    ## [G449] A decoded request: what a waiting request holds, and nothing more.
    case kind*: OperationKind
    of opInspect, opInstall, opUpdate:
      root*: RootReference ## an update's has `newerThan`, its `current`
    of opRemove:
      identity*: PackageIdentity

  OperationAnswerKind* = enum
    oaResponse ## the §15 response value: a success or a `package_error`
    oaModuleError
      ## the invocation error `MODULE_ERROR` (PM l.1516-1517): a full queue, or an
      ## admission bound (G452)
    oaEncoded ## a §15 response value already encoded

  OperationAnswer* = object
    case kind*: OperationAnswerKind
    of oaResponse:
      response*: CborValue
    of oaModuleError:
      reason*: string ## for the caller's invocation error and the log
    of oaEncoded:
      encoded*: string
        ## the §15 response value, deterministic CBOR the worker encoded (Fable's
        ## check §3, §4): passed through

  SnapRecord* = ref object
    ## [G449; Fable's check §4] One committed record as operations read it: immutable once
    ## made, and shared by every snapshot that names it.
    package*: InstalledPackage ## the resolver's view
    rid*: string
    generation*: uint64
    base*: string ## its `a/` directory
    artifacts*: seq[InstalledArtifact] ## for the retained check

  Snapshot* = ref object
    ## [G445, G449] The installed state as of one commit, immutable: a new one replaces
    ## it after each index commit (PKG-0410). Each running operation holds the one
    ## current at its start.
    sequence*: uint64 ## the commit it reflects
    records*: seq[SnapRecord] ## in index order

  BindingStatus* = object
    name*: string
    instance*: string
    state*: RouteState
    route*: string
    readiness*: Opt[Readiness]

  Engine* = object
    input*: PmInput
    keys: KeySource
    catalog*: CatalogState
    cache*: VerificationCache
    bindings: seq[Binding]
    catalogBinding: int
    acquired: bool ## the catalog was accepted or refused this start
    acquiring: bool ## a catalog job is queued or running
    acquireBackoff: int
    acquireTimer: uint64
    requests: Table[uint64, Driver]
    releasing: seq[Driver] ## [G455] finished or cancelled, freed a turn at a time
    releaseQueued: bool ## a `ReleaseOperation` continue is issued
    turnWork: int64 ## [G455] the work of one resolution turn
    calls: Table[uint64, (int, uint64, int)] ## call id -> (binding, job, generation)
    timers: Table[uint64, TimerTarget]
    unknownLogged: HashSet[string]
    spools: Table[uint64, Spool] ## [G447] by the retrieval job's id
    shareUsed: int64 ## [G446] the spool's bytes the archives hold
    mutationUsed: int64 ## [G446] the bytes the running mutation's spool files hold
    budgetArchives: int ## [G446] `SpoolBudgetArchives`; the tests give others
    evictions: int ## [G446] archives a mutation's budget deleted, since the start
    shareWaiters: seq[(int, uint64)] ## [G446] (binding, job), first in, first out
    dropping: seq[seq[InspectedDependency]]
      ## [G447, G482] the entries of judgments whose operation went, freed a turn at a time
    decodeQueued: bool ## a `DecodeOperation` continue is issued
    slots: array[SlotKind, Slot] ## [G449]
    operations: Table[uint64, Operation] ## [G449] running or waiting, by request
    snapshot: Snapshot ## [G449] the current one
    held: Table[uint64, int]
      ## [G445 R1] the operations holding each snapshot, by sequence
    retired: seq[Retired] ## [R1] what commits stopped naming, until a collect deletes it
    collecting: bool ## a `wjCollect` runs
    committing: Table[uint64, CommitPending] ## [5-5-4] by request
    queries: Table[uint64, Snapshot]
      ## [5-5-4; plan §4.6] queries (a handoff) that do not queue, each holding the snapshot
      ## it read until its answer
    installedChanges*: int
      ## [plan §4.6] installed-state changes, a signer replacement included, for 5-6b's watch
    clock: Clock
    next: uint64
    started: bool
    stopped*: bool

# Construction -----------------------------------------------------------------------

proc monotonicMs(): int64 {.gcsafe, raises: [].} =
  getMonoTime().ticks div 1_000_000

proc initEngine*(
    input: PmInput,
    keptBytes: Opt[seq[byte]],
    keys: KeySource,
    platform = hostPlatform(),
    pathRules = hostPathRules(),
    turnWork = ResolverTurnWork,
    clock: Clock = nil,
    spoolBudgetArchives = SpoolBudgetArchives,
): (Engine, seq[Command]) =
  ## The engine at `_init`, before any I/O: the catalog state from the kept
  ## file (`keptBytes`), and the log lines that start produced. The resolver
  ## limits are the input's (G399, planning's ruling of 2026-11-22): no caller
  ## can pass values the input does not hold. So are the operation bound
  ## (`operation_entries`, G477) and the LGX limits, G75's table scaled to
  ## `archive_bytes` (G453). `turnWork` is the work of one resolution turn
  ## (G455): `ResolverTurnWork`, a constant; the tests give others, which change
  ## no outcome.
  doAssert turnWork > 0, "a turn spends some work"
  doAssert spoolBudgetArchives >= 1, "the budget holds one archive at least"
  let lgxLimits = scaledLimits(DefaultLgxLimits, input.limits.archiveBytes)
  var e = Engine(
    input: input,
    keys: keys,
    turnWork: turnWork,
    clock: (if clock.isNil: Clock(monotonicMs) else: clock),
      # the conversion first: Nim 2.2.14 types the `if` by its first branch, and with
      # `--os:linux` a bare `monotonicMs` stays `nimcall`, which a closure cannot join
    budgetArchives: spoolBudgetArchives,
    snapshot: Snapshot(),
    cache:
      initVerificationCache(input.limits.cacheEntries, platform, lgxLimits, pathRules),
    catalogBinding: -1,
  )
  var cmds: seq[Command]
  let (state, note) = initCatalogState(input.catalog, input.limits, keptBytes)
  e.catalog = state
  if note.isSome:
    cmds.add(Command(kind: cmLog, text: note.get))
  if e.catalog.inUse.isSome:
    let c = e.catalog.inUse.get
    cmds.add(
      Command(
        kind: cmLog,
        text:
          "the kept catalog is in use: sequence " & $c.sequence & ", " & $c.entries.len &
          " entries, digest " & c.digest.toHex,
      )
    )
  for i, b in input.bindings:
    e.bindings.add(Binding(name: b.name, instance: b.instance))
    if b.name == input.catalog.storage:
      e.catalogBinding = i
  doAssert e.catalogBinding >= 0 # checkedValue's rule
  (e, cmds)

# Ids, timers and status -------------------------------------------------------------

proc nextId(e: var Engine): uint64 =
  inc e.next
  e.next

proc timer(
    e: var Engine, cmds: var seq[Command], target: TimerTarget, ms: uint32
): uint64 =
  let id = e.nextId()
  e.timers[id] = target
  cmds.add(Command(kind: cmTimer, timer: id, ms: ms))
  id

proc log(cmds: var seq[Command], text: string) =
  cmds.add(Command(kind: cmLog, text: text))

func index(e: Engine, name: string): int =
  for i, b in e.bindings:
    if b.name == name:
      return i
  -1

func status*(e: Engine): seq[BindingStatus] =
  for b in e.bindings:
    result.add(
      BindingStatus(
        name: b.name,
        instance: b.instance,
        state: b.state,
        route: b.route,
        readiness: b.readiness,
      )
    )

func catalogInUse*(e: Engine): Opt[Catalog] =
  e.catalog.inUse

func pendingRequests*(e: Engine): int =
  e.requests.len

func releasingRuns*(e: Engine): int =
  ## [G455] The finished or cancelled operations' runs still being freed.
  e.releasing.len

func spooled*(e: Engine): int =
  ## [G447] The spool files the engine holds: retrieved, being written, or judged.
  e.spools.len

func shareUsed*(e: Engine): int64 =
  ## [G446] The bytes of the inspections' share the spool files hold.
  e.shareUsed

func mutationSpoolUsed*(e: Engine): int64 =
  ## [G446] The bytes the running mutation's spool files hold.
  e.mutationUsed

func spoolEvictions*(e: Engine): int =
  ## [G446] The archives mutations' budgets deleted since the start.
  e.evictions

func keptArchives*(e: Engine, request: uint64): int =
  ## [G446] The operation's judged archives still in the spool.
  for sp in e.spools.values:
    if sp.request == request and sp.kept:
      inc result

func shareWaiting*(e: Engine): int =
  ## [G446] The retrievals waiting for their part of the share (stale entries included
  ## until reached).
  e.shareWaiters.len

func droppingJudgments*(e: Engine): int =
  ## [G447, G482] The dropped judgments whose entries are still being freed a turn at a time.
  e.dropping.len

func slotRunning*(e: Engine, slot: SlotKind): Opt[uint64] =
  ## [G449] The operation holding `slot`.
  e.slots[slot].running

func slotWaiting*(e: Engine, slot: SlotKind): int =
  ## [G449] The requests waiting for `slot`.
  e.slots[slot].waiting

func snapshot*(e: Engine): Snapshot =
  e.snapshot

func heldSnapshots*(e: Engine): int =
  ## [G445 R1] The operations holding a snapshot.
  for _, n in e.held:
    result += n

func snapRecord*(
    r: InstalledRecord,
    dependencies: openArray[PackageDependency],
    base: string,
    rid = "",
    generation = 0'u64,
): SnapRecord =
  ## [G449] One committed record, as resolution reads it (`dependencies` are its signed
  ## manifest's) and as the retained check finds its files.
  SnapRecord(
    package: InstalledPackage(
      identity: r.identity,
      commitment: r.commitment,
      signer: r.signer,
      source: r.source,
      modules: r.modules,
      dependencies: @dependencies,
      resolvedDependencies: r.resolvedDependencies,
    ),
    rid: rid,
    generation: generation,
    base: base,
    artifacts: r.artifacts,
  )

proc addRecord*(
    s: Snapshot,
    r: InstalledRecord,
    dependencies: openArray[PackageDependency],
    base: string,
    rid = "",
    generation = 0'u64,
) =
  s.records.add(snapRecord(r, dependencies, base, rid, generation))

func packages*(s: Snapshot): seq[InstalledPackage] =
  ## The resolver's `installed` input: a copy of each record's view, made at each
  ## resolution's start (measured: `tools/pmbench.nim`).
  for r in s.records:
    result.add(r.package)

when defined(posix):
  proc snapshotOf*(store: InstalledStore): Snapshot =
    ## [G449] The installed state the store holds, as operations read it.
    result = Snapshot(sequence: store.sequence)
    for i in store.records:
      result.addRecord(
        i.file.record, i.manifest.dependencies, i.base, i.rid, i.file.generation
      )

proc setSnapshot*(e: var Engine, s: Snapshot) =
  ## [G449] The installed state the store loaded: operations that take their slot from
  ## now on hold it (PKG-0410). Commits replace it themselves.
  doAssert not s.isNil and s.sequence >= e.snapshot.sequence
  e.snapshot = s

func next*(
    s: Snapshot, sequence: uint64, add: Opt[SnapRecord], drop: openArray[string]
): Snapshot =
  ## [Fable's check §4] The snapshot after a commit: unchanged records shared, `drop` (rids)
  ## gone, `add` inserted in identity order or replacing its rid's record.
  result = Snapshot(sequence: sequence)
  for r in s.records:
    if r.rid in drop or (add.isSome and add.get.rid == r.rid):
      continue
    result.records.add(r)
  if add.isSome:
    let r = add.get
    let at = result.records.upperBound(
      r,
      proc(a, b: SnapRecord): int =
        identityOrder(a.package.identity, b.package.identity),
    )
    result.records.insert(r, at)

proc workerConfig*(e: Engine, spoolDir: string): WorkerConfig =
  ## [G447] What the shell starts the worker with: the inputs the cache judges by.
  workerConfig(
    spoolDir, e.input.trustBytes, e.cache.platform, e.cache.lgxLimits, e.cache.pathRules
  )

func queued*(e: Engine, binding: string): int =
  let i = e.index(binding)
  if i < 0:
    0
  else:
    e.bindings[i].jobs.len

func usable(b: Binding): bool =
  b.state == rsReady

# Routes -----------------------------------------------------------------------------

proc failJobs(e: var Engine, bi: int, reason: string, cmds: var seq[Command])
proc resumeRoute(e: var Engine, bi: int, cmds: var seq[Command])

proc establish(e: var Engine, bi: int, cmds: var seq[Command]) =
  let key = e.keys()
  template b(): untyped =
    e.bindings[bi]

  if key.len == 0:
    cmds.log(
      "binding " & b.name.escape & ": no fresh request key; establishment refused"
    )
    b.state = rsBackoff
    let ms = RouteBackoffMs[min(b.backoff, RouteBackoffMs.high)]
    inc b.backoff
    discard e.timer(cmds, TimerTarget(kind: tkRoute, binding: bi), ms)
    e.failJobs(bi, "the route to the binding's provider is not established", cmds)
    return
  b.key = key
  b.lost = 0
  b.state = rsEstablishing
  cmds.add(Command(kind: cmEstablish, binding: b.name, instance: b.instance, key: key))

proc refused(e: var Engine, bi: int, reason: string, cmds: var seq[Command]) =
  template b(): untyped =
    e.bindings[bi]

  cmds.log(
    "binding " & b.name.escape & ": the route to " & b.instance.escape & " was refused: " &
      reason.escape
  )
  b.state = rsBackoff
  b.route = ""
  b.readiness = Opt.none(Readiness)
  let ms = RouteBackoffMs[min(b.backoff, RouteBackoffMs.high)]
  inc b.backoff
  discard e.timer(cmds, TimerTarget(kind: tkRoute, binding: bi), ms)
  e.failJobs(bi, "the route to the binding's provider was refused", cmds)

proc routeReady(e: var Engine, bi: int, cmds: var seq[Command]) =
  template b(): untyped =
    e.bindings[bi]

  b.state = rsReady
  inc b.generation
  b.backoff = 0
  b.lost = 0
  b.readiness = Opt.none(Readiness)
  cmds.add(
    Command(kind: cmWatch, binding: b.name, instance: b.instance, route: b.route)
  )
  e.resumeRoute(bi, cmds)

proc lose(e: var Engine, bi: int, cmds: var seq[Command]) =
  ## The binding's ready route is lost: renew it under a new key.
  template b(): untyped =
    e.bindings[bi]

  if b.state != rsReady:
    return
  b.readiness = Opt.none(Readiness)
  let key = e.keys()
  if key.len == 0:
    cmds.add(
      Command(kind: cmRelease, binding: b.name, instance: b.instance, route: b.route)
    )
    b.route = ""
    e.establish(bi, cmds)
    return
  b.key = key
  b.lost = 0
  b.state = rsRenewing
  cmds.add(
    Command(
      kind: cmRenew, binding: b.name, instance: b.instance, route: b.route, key: key
    )
  )

proc onEstablished(e: var Engine, ev: Event, cmds: var seq[Command]) =
  let bi = e.index(ev.binding)
  if bi < 0:
    return
  template b(): untyped =
    e.bindings[bi]

  if ev.key != b.key:
    return # a stale answer
  if ev.kind == evEstablished and b.state == rsEstablishing:
    case ev.answer
    of raReady:
      b.route = ev.route
      e.routeReady(bi, cmds)
    of raLost:
      inc b.lost
      if b.lost > MaxLostResponses:
        e.refused(bi, "no response to " & $MaxLostResponses & " retries", cmds)
      else:
        cmds.add(
          Command(kind: cmEstablish, binding: b.name, instance: b.instance, key: b.key)
        )
    of raRefused:
      e.refused(bi, ev.reason, cmds)
  elif ev.kind == evRenewed and b.state == rsRenewing:
    case ev.answer
    of raReady:
      e.routeReady(bi, cmds)
    of raLost:
      inc b.lost
      if b.lost <= MaxLostResponses:
        cmds.add(
          Command(
            kind: cmRenew,
            binding: b.name,
            instance: b.instance,
            route: b.route,
            key: b.key,
          )
        )
        return
      cmds.add(
        Command(kind: cmRelease, binding: b.name, instance: b.instance, route: b.route)
      )
      b.route = ""
      e.establish(bi, cmds)
    of raRefused:
      cmds.log(
        "binding " & b.name.escape & ": the route could not be renewed: " &
          ev.reason.escape
      )
      cmds.add(
        Command(kind: cmRelease, binding: b.name, instance: b.instance, route: b.route)
      )
      b.route = ""
      e.establish(bi, cmds)

# Jobs -------------------------------------------------------------------------------

proc startHead(e: var Engine, bi: int, cmds: var seq[Command])
proc deliver(e: var Engine, bi: int, job: Job, step: FetchStep, cmds: var seq[Command])

proc apply(
    e: var Engine, bi: int, step: FetchStep, waitFor: JobWait, cmds: var seq[Command]
) =
  ## Carries out the head job's next step.
  template b(): untyped =
    e.bindings[bi]

  template j(): untyped =
    e.bindings[bi].jobs[0]

  case step.kind
  of skCall:
    if b.state == rsBackoff or b.state == rsStopped:
      e.apply(
        bi,
        FetchStep(
          kind: skUnavailable,
          reason: "the route to the binding's provider is not established",
        ),
        jwNone,
        cmds,
      )
      return
    if j.fetch.spooled and e.spools.getOrDefault(j.id).unacked >= SpoolLag:
      j.wait = jwSpool # [G447] an acknowledgement resumes it
      return
    if not b.usable:
      j.wait = jwRoute
      j.timer = e.timer(
        cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), j.fetch.deadlineMs
      )
      return
    let id = e.nextId()
    j.call = id
    j.wait = jwCall
    e.calls[id] = (bi, j.id, b.generation)
    case step.call.kind
    of ckStat:
      cmds.add(
        Command(
          kind: cmStat,
          call: id,
          target: b.name,
          locator: j.fetch.locator,
          deadlineMs: j.fetch.deadlineMs,
        )
      )
    of ckRead:
      cmds.add(
        Command(
          kind: cmRead,
          call: id,
          target: b.name,
          locator: j.fetch.locator,
          offset: step.call.offset,
          length: step.call.length,
          deadlineMs: j.fetch.deadlineMs,
        )
      )
    j.timer = e.timer(
      cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), j.fetch.deadlineMs
    )
  of skWait:
    j.wait = waitFor
    j.timer = e.timer(cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), step.ms)
  of skBackoff:
    j.wait = jwBackoff
    j.timer = e.timer(cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), step.ms)
  of skDone, skUnavailable:
    let job = e.bindings[bi].jobs[0]
    e.bindings[bi].jobs.delete(0)
    e.bindings[bi].active = false
    if job.call != 0:
      e.calls.del(job.call)
    e.deliver(bi, job, step, cmds)
    e.startHead(bi, cmds)

proc startHead(e: var Engine, bi: int, cmds: var seq[Command]) =
  if e.bindings[bi].active or e.bindings[bi].jobs.len == 0 or e.stopped:
    return
  e.bindings[bi].active = true
  let step = e.bindings[bi].jobs[0].fetch.start()
  e.apply(bi, step, jwNone, cmds)

proc enqueue(e: var Engine, bi: int, job: sink Job, cmds: var seq[Command]) =
  e.bindings[bi].jobs.add(job)
  e.startHead(bi, cmds)

proc failJobs(e: var Engine, bi: int, reason: string, cmds: var seq[Command]) =
  ## Every job of the binding ends unavailable: its route was refused. A job a
  ## delivery adds meanwhile fails the same way when it starts.
  while e.bindings[bi].jobs.len > 0:
    e.bindings[bi].active = true
    e.bindings[bi].jobs[0].wait = jwNone
    e.apply(bi, FetchStep(kind: skUnavailable, reason: reason), jwNone, cmds)

proc resumeRoute(e: var Engine, bi: int, cmds: var seq[Command]) =
  ## The route is ready: a head job waiting for it issues its call again.
  if e.bindings[bi].jobs.len == 0 or not e.bindings[bi].active:
    e.startHead(bi, cmds)
    return
  if e.bindings[bi].jobs[0].wait == jwRoute:
    e.bindings[bi].jobs[0].wait = jwNone
    e.bindings[bi].jobs[0].timer = 0
    let step = e.bindings[bi].jobs[0].fetch.resume()
    e.apply(bi, step, jwNone, cmds)

proc resumeReady(e: var Engine, bi: int, cmds: var seq[Command]) =
  if e.bindings[bi].jobs.len == 0 or not e.bindings[bi].active:
    return
  if e.bindings[bi].jobs[0].wait == jwReady:
    e.bindings[bi].jobs[0].wait = jwNone
    e.bindings[bi].jobs[0].timer = 0
    let step = e.bindings[bi].jobs[0].fetch.resume()
    e.apply(bi, step, jwNone, cmds)

# The catalog ------------------------------------------------------------------------

proc acquire(e: var Engine, cmds: var seq[Command]) =
  ## [G401] Reads the configured catalog when it is still to be read and its
  ## binding is ready.
  let bi = e.catalogBinding
  if e.acquired or e.acquiring or e.stopped:
    return
  if not e.bindings[bi].usable or e.bindings[bi].readiness != Opt.some(rdReady):
    return
  e.acquiring = true
  e.acquireTimer = 0
  let job = Job(
    id: e.nextId(),
    catalog: true,
    fetch: initRetrieval(
      e.input.catalog.locator,
      int64(e.input.limits.catalogBytes),
      e.input.limits.readDeadlineMs,
    ),
  )
  e.enqueue(bi, job, cmds)

proc catalogDone(e: var Engine, step: FetchStep, cmds: var seq[Command]) =
  e.acquiring = false
  case step.kind
  of skDone:
    e.acquired = true
    let r = e.catalog.offer(step.bytes)
    if r.isErr:
      cmds.log("the configured catalog is refused: " & r.error)
      return
    let c = r.get.catalog
    cmds.log(
      "the configured catalog is in use: sequence " & $c.sequence & ", " & $c.entries.len &
        " entries, digest " & c.digest.toHex
    )
    if r.get.keptBytes.isSome:
      cmds.add(Command(kind: cmWriteKept, kept: r.get.keptBytes.get))
  of skUnavailable:
    cmds.log("the configured catalog could not be read: " & step.reason)
    let bi = e.catalogBinding
    if e.bindings[bi].usable and e.bindings[bi].readiness == Opt.some(rdReady):
      let ms = AcquireBackoffMs[min(e.acquireBackoff, AcquireBackoffMs.high)]
      inc e.acquireBackoff
      e.acquireTimer = e.timer(cmds, TimerTarget(kind: tkAcquire, binding: bi), ms)
  else:
    discard

# Resolution -------------------------------------------------------------------------

func limitValue(e: Engine, name: string): int =
  ## The configured value of the resolver limit `name` (`ResolverCounters.limit`).
  let l = e.input.resolverLimits
  case name
  of "partial_closure_names": l.names
  of "dependency_depth": l.depth
  of "candidates_per_name": l.candidates
  else: l.attempts

proc retire(e: var Engine, d: sink Driver, cmds: var seq[Command]) =
  ## [G455] `d`'s run is freed by later turns, one at a time.
  e.releasing.add(d)
  if not e.releaseQueued:
    e.releaseQueued = true
    cmds.add(Command(kind: cmContinue, operation: ReleaseOperation))

proc releaseTurn(e: var Engine, cmds: var seq[Command]) =
  e.releaseQueued = false
  if e.releasing.len == 0:
    return
  if e.releasing[0].release():
    e.releasing.delete(0)
  if e.releasing.len > 0:
    e.releaseQueued = true
    cmds.add(Command(kind: cmContinue, operation: ReleaseOperation))

proc resolved(
  e: var Engine,
  request: uint64,
  outcome: sink Result[Resolution, PackageError],
  cmds: var seq[Command],
)

proc askRetained(e: var Engine, request: uint64, record: int, cmds: var seq[Command])

proc advanceRequest(e: var Engine, request: uint64, cmds: var seq[Command]) =
  let d = e.requests.getOrDefault(request)
  if d.isNil:
    return
  while true:
    var s = d.step()
    case s.kind
    of dsDone:
      e.requests.del(request)
      let tripped = d.counters.limit
      if tripped.len > 0:
        # [G399; ruling M5] The operator's log names the limit, with its value:
        # the caller sees only `dependency-unavailable` (PM l.1501-1502, l.1514).
        cmds.log(
          "a root operation stopped at the resolver limit " & tripped & " (" &
            $e.limitValue(tripped) & ")"
        )
      if d.counters.bound.len > 0:
        # [G477] So does the operation bound, with its value: the caller sees only
        # `package-unavailable` (PM l.1308-1309, l.1514).
        cmds.log(
          "a root operation stopped at the operation bound " & d.counters.bound & " (" &
            $e.input.limits.operationEntries & ")"
        )
      e.retire(d, cmds)
      if request in e.operations:
        e.resolved(request, move s.outcome, cmds)
      else:
        cmds.add(Command(kind: cmReply, request: request, outcome: move s.outcome))
      return
    of dsTurn:
      # [G455] The turn's work is spent: the next one comes in a later turn of
      # the event loop.
      cmds.add(Command(kind: cmContinue, operation: request))
      return
    of dsRetained:
      if request in e.operations:
        # [G448] Hashed on the worker; the answer resumes the run.
        e.askRetained(request, s.record, cmds)
        return
      # [G455] `resolve` (5-3b's and 5-3c's probe) has no installed state, so no
      # record is asked for.
      d.supplyRetained(s.record, Result[void, string].err("no installed state"))
      continue
    of dsNeed:
      let source = s.source
      let bi = e.index(source.storage)
      if bi < 0:
        if source.storage notin e.unknownLogged:
          e.unknownLogged.incl(source.storage)
          cmds.log(
            "a source names the binding " & source.storage.escape &
              ", which is not configured"
          )
        d.supply(
          source,
          Inspection(
            kind: ikUnavailable, reason: "the source names no configured binding"
          ),
        )
        continue
      let job = Job(
        id: e.nextId(),
        request: request,
        source: source,
        fetch: initRetrieval(
          source.objectLocator,
          e.input.limits.archiveBytes,
          e.input.limits.readDeadlineMs,
          spooled = true,
        ),
      )
      e.enqueue(bi, job, cmds)
      return

# Spool files and the worker (G446, G447) ----------------------------------------------

proc work(cmds: var seq[Command], job: sink WorkerJob) =
  cmds.add(Command(kind: cmWork, job: job))

func shareCap(e: Engine): int64 =
  ## [IMPL; G446] The inspections' share of the spool.
  int64(SpoolShareArchives) * e.input.limits.archiveBytes

func fetching(e: Engine, request: uint64): bool =
  ## A resolution runs for `request`, or [G446] its operation fetches an evicted archive
  ## again.
  if request in e.requests:
    return true
  e.operations.withValue(request, op):
    return op.phase == mpRefetching
  false

proc refetchFailed(
  e: var Engine, request: uint64, reason: string, cmds: var seq[Command]
)

proc supplyTo(
    e: var Engine,
    request: uint64,
    source: PackageSource,
    x: sink Inspection,
    cmds: var seq[Command],
) =
  ## The archive's inspection, to its operation if that is still running. [G446] For a
  ## refetch, only an unavailable archive comes here: its operation fails.
  let d = e.requests.getOrDefault(request)
  if d.isNil:
    if x.kind == ikUnavailable:
      e.refetchFailed(request, x.reason, cmds)
    return
  d.supply(source, x)
  e.advanceRequest(request, cmds)

proc reserve(e: var Engine, bi: int, size: int64) =
  ## [G446] The head job's archive takes `size` bytes of the share; its first piece
  ## creates its spool file.
  template j(): untyped =
    e.bindings[bi].jobs[0]

  e.shareUsed += size
  e.spools[j.id] =
    Spool(request: j.request, source: j.source, binding: bi, reserved: size)

proc append(e: var Engine, file: uint64, chunk: sink string, cmds: var seq[Command]) =
  ## [G447] A piece for the worker, the first creating the spool file.
  var sp = addr e.spools.mgetOrPut(file, Spool())
  var job = WorkerJob(kind: wjAppend, file: file, chunk: chunk)
  if not sp.created:
    sp.created = true
    job.first = true
    job.name = spoolName(sp.request, file)
  inc sp.unacked
  cmds.work(job)

proc fits(e: Engine, size: int64): bool =
  e.shareUsed == 0 or e.shareUsed + size <= e.shareCap

proc grantShare(e: var Engine, cmds: var seq[Command]) =
  ## [G446] The waiting retrievals that now fit, first in, first out.
  while e.shareWaiters.len > 0 and not e.stopped:
    let (bi, id) = e.shareWaiters[0]
    template j(): untyped =
      e.bindings[bi].jobs[0]

    if e.bindings[bi].jobs.len == 0 or j.id != id or j.wait != jwShare:
      e.shareWaiters.delete(0) # it ended meanwhile
      continue
    let size = int64(j.fetch.size.get(0))
    if not e.fits(size):
      return
    e.shareWaiters.delete(0)
    j.wait = jwNone
    e.reserve(bi, size)
    let step =
      if j.fetch.finished:
        FetchStep(kind: skDone)
      else:
        j.fetch.resume()
    e.apply(bi, step, jwNone, cmds)

proc unspool(e: var Engine, file: uint64, cmds: var seq[Command]) =
  ## [G446] The archive's spool file is deleted and its share released.
  var sp: Spool
  if not e.spools.pop(file, sp):
    return
  cmds.work(WorkerJob(kind: wjDrop, file: file))
  if sp.mutation:
    e.mutationUsed -= sp.reserved
  else:
    e.shareUsed -= sp.reserved
    e.grantShare(cmds)

func isMutation(e: Engine, request: uint64): bool =
  request in e.operations and e.operations.getOrDefault(request).slot == slMutation

proc keep(e: var Engine, file: uint64, eligible: bool) =
  ## [G446] A mutation's judged archive stays for extraction; its first eligible one is
  ## the root's, which its budget never deletes (Fable's recheck).
  var sp = addr e.spools.mgetOrPut(file, Spool())
  sp.kept = true
  sp.eligible = eligible
  e.operations.withValue(sp.request, op):
    if eligible and not op.rootKept:
      op.rootKept = true
      sp.root = true

proc makeRoom(e: var Engine, request: uint64, size: int64, cmds: var seq[Command]) =
  ## [G446; plan §4.3] While a new archive of `size` would pass the operation's budget,
  ## its kept archives are deleted: never the root's, never one being written; first the
  ## ineligible, then the rest, oldest first. Each deleted one is recorded, to be fetched
  ## again by digest if it is selected. With nothing left to delete the archive is
  ## spooled all the same: the budget is never smaller than one archive.
  let cap = int64(e.budgetArchives) * e.input.limits.archiveBytes
  while e.mutationUsed + size > cap:
    var pick = 0'u64
    var pickEligible = true
    for id, sp in e.spools:
      if sp.request != request or not sp.kept or sp.root:
        continue
      if pick == 0 or (pickEligible and not sp.eligible) or
          (pickEligible == sp.eligible and id < pick):
        pick = id
        pickEligible = sp.eligible
    if pick == 0:
      return
    let sp = e.spools.getOrDefault(pick)
    e.operations.withValue(request, op):
      op.evicted.add(
        Evicted(
          source: sp.source,
          digest: sp.digest,
          identity: sp.identity,
          commitment: sp.commitment,
          signer: sp.signer,
          variant: sp.variant,
          judged: sp.judged,
        )
      )
    inc e.evictions
    e.unspool(pick, cmds)

proc spoolFailed(failure: string): string =
  "the archive could not be written to the spool on the state directory's file system: " &
    failure

proc queueDropTurn(e: var Engine, cmds: var seq[Command]) =
  if e.dropping.len > 0 and not e.decodeQueued:
    e.decodeQueued = true
    cmds.add(Command(kind: cmContinue, operation: DecodeOperation))

proc dropTurn(e: var Engine, cmds: var seq[Command]) =
  ## [G447, G482] One turn of freeing: at most `DecodeTurnUnits` dependency entries of
  ## judgments whose operation went (Fable's D1 condition 5; its archive is no other
  ## operation's, which retrieves and judges its own).
  e.decodeQueued = false
  var budget = DecodeTurnUnits
  while budget > 0 and e.dropping.len > 0:
    if e.dropping[0].releaseSome(budget):
      e.dropping.delete(0)
  e.queueDropTurn(cmds)

proc spoolEnds(e: var Engine, file: uint64, reason: string, cmds: var seq[Command]) =
  ## [G446] A spool file failed while its retrieval runs: the retrieval ends now.
  let bi = e.spools.getOrDefault(file).binding
  if e.bindings[bi].jobs.len == 0 or e.bindings[bi].jobs[0].id != file or
      not e.bindings[bi].active:
    return
  template j(): untyped =
    e.bindings[bi].jobs[0]

  if j.call != 0:
    e.calls.del(j.call) # its answer is ignored
    j.call = 0
  j.timer = 0
  j.wait = jwNone
  let step = j.fetch.abandon(reason)
  e.apply(bi, step, jwNone, cmds)

func identityKey(i: PackageIdentity): string =
  i.package & "\0" & i.version

func judgedKey(i: PackageIdentity, c: ManifestCommitment): string =
  i.identityKey & "\0" & $c

proc onStaged(e: var Engine, r: sink WorkerResult, cmds: var seq[Command])
proc refetched(
  e: var Engine,
  file: uint64,
  digest: Blake3Digest,
  failure: string,
  cmds: var seq[Command],
)

proc onCommitted(e: var Engine, r: sink WorkerResult, cmds: var seq[Command])
proc onReply(e: var Engine, r: sink WorkerResult, cmds: var seq[Command])
proc onCollected(e: var Engine, r: sink WorkerResult, cmds: var seq[Command])

func rootCandidate(e: Engine, request: uint64, source: PackageSource): (string, bool) =
  ## [5-5-4] For an inspection: its root's package name, and whether `source` is its
  ## root source. An eligible archive of either has its `{inspection}` encoded by the
  ## worker.
  e.operations.withValue(request, op):
    if op.request.kind == opInspect:
      let root = op.request.root
      return (root.package.get(""), root.source.isSome and root.source.get == source)
  ("", false)

proc judged(
    e: var Engine,
    file: uint64,
    identity: PackageIdentity,
    commitment: ManifestCommitment,
    signer: PackageSigner,
    variant: string,
) =
  ## [Fable's check §2] What a mutation's kept archive was judged to give: `wjStage`
  ## sends it, and the worker compares.
  e.spools.withValue(file, sp):
    sp.judged = true
    sp.identity = identity
    sp.commitment = commitment
    sp.signer = signer
    sp.variant = variant

proc onWorked(e: var Engine, r: sink WorkerResult, cmds: var seq[Command]) =
  ## [G447] The worker's answer about spool file `r.file`; one the engine dropped is
  ## ignored. [G448] A retained check's answer resumes its operation's run, if that is
  ## still running. [5-5-4] The store's answers go to their operation.
  case r.kind
  of wrStaged:
    e.onStaged(move r, cmds)
    return
  of wrCommitted:
    e.onCommitted(move r, cmds)
    return
  of wrReply:
    e.onReply(move r, cmds)
    return
  of wrCollected:
    e.onCollected(move r, cmds)
    return
  else:
    discard
  if r.kind == wrRetained:
    let d = e.requests.getOrDefault(r.request)
    if d.isNil or r.request notin e.operations:
      return
    d.supplyRetained(
      r.record,
      if r.failure.len == 0:
        Result[void, string].ok()
      else:
        Result[void, string].err(r.failure),
    )
    e.advanceRequest(r.request, cmds)
    return
  if r.file notin e.spools:
    return
  template sp(): untyped =
    e.spools.mgetOrPut(r.file, Spool())
      # present: checked above, and read before `unspool`

  case r.kind
  of wrAppended:
    dec sp.unacked
    if sp.phase != spWriting:
      return
    let bi = sp.binding
    if r.failure.len > 0:
      cmds.log(spoolFailed(r.failure))
      e.spoolEnds(r.file, "the archive could not be spooled", cmds)
      return
    if e.bindings[bi].jobs.len > 0 and e.bindings[bi].jobs[0].id == r.file and
        e.bindings[bi].jobs[0].wait == jwSpool and sp.unacked < SpoolLag:
      e.bindings[bi].jobs[0].wait = jwNone
      let step = e.bindings[bi].jobs[0].fetch.resume()
      e.apply(bi, step, jwNone, cmds)
  of wrDigest:
    let (request, source) = (sp.request, sp.source)
    if sp.refetch:
      e.refetched(r.file, r.digest, r.failure, cmds)
      return
    if request notin e.requests:
      e.unspool(r.file, cmds)
      return
    if r.failure.len > 0:
      cmds.log(spoolFailed(r.failure))
      e.unspool(r.file, cmds)
      e.supplyTo(
        request,
        source,
        Inspection(kind: ikUnavailable, reason: "the archive could not be spooled"),
        cmds,
      )
      return
    let (rootPackage, rootSource) = e.rootCandidate(request, source)
    var hit = e.cache.lookup(r.digest, e.input.trust)
    if hit.isSome and hit.get.kind == ikEligible and
        (rootSource or hit.get.identity.package == rootPackage):
      # [5-5-4] an inspection's root candidate is judged on the worker, which encodes
      # its `{inspection}` response then
      hit = Opt.none(Inspection)
    if hit.isSome:
      if sp.mutation:
        sp.digest = r.digest
        e.keep(r.file, hit.get.kind == ikEligible)
        let entry = e.cache.entryOf(r.digest)
        if hit.get.kind == ikEligible and entry.isSome:
          let x = entry.get
          e.judged(
            r.file,
            x.identity,
            x.commitment,
            PackageSigner(profile: x.profile, key: x.key),
            x.variant,
          )
      else:
        e.unspool(r.file, cmds)
      e.supplyTo(request, source, hit.get, cmds)
      return
    sp.digest = r.digest
    sp.phase = spOpening
    cmds.work(
      WorkerJob(
        kind: wjOpen,
        file: r.file,
        source: (if rootPackage.len > 0 or rootSource: source.sourceBytes else: ""),
        rootPackage: rootPackage,
        rootSource: rootSource,
      )
    )
  of wrOpened:
    let (request, source, digest) = (sp.request, sp.source, sp.digest)
    if sp.mutation and request in e.requests:
      e.keep(r.file, r.opened.inspection.kind == ikEligible)
      if r.opened.inspection.kind == ikEligible:
        e.judged(
          r.file,
          r.opened.inspection.identity,
          r.opened.inspection.commitment,
          PackageSigner(profile: r.opened.profile, key: r.opened.key),
          r.opened.variant,
        )
    else:
      e.unspool(r.file, cmds)
    if r.reply.len > 0 and request in e.requests:
      e.operations.withValue(request, op):
        op.inspections[
          judgedKey(r.opened.inspection.identity, r.opened.inspection.commitment)
        ] = move r.reply
    if request notin e.requests:
      # [G482] Its encodings go now, two blocks; its entries in turns when there are many.
      if r.opened.inspection.kind == ikEligible and
          r.opened.inspection.dependencies.len > DecodeTurnUnits:
        e.dropping.add(move r.opened.inspection.dependencies)
        e.queueDropTurn(cmds)
      return
    # [G447, G482] Admitted and supplied in the turn it arrives: nothing is decoded. The
    # cache's estimate is by lengths.
    let estimate = r.opened.inspection.estimatedBytes
    let x = e.cache.admit(digest, move r.opened, estimate)
    e.supplyTo(request, source, x, cmds)
  of wrRetained, wrStaged, wrCommitted, wrReply, wrCollected:
    discard # answered above

proc deliver(
    e: var Engine, bi: int, job: Job, step: FetchStep, cmds: var seq[Command]
) =
  if job.catalog:
    e.catalogDone(step, cmds)
    return
  if job.fetch.spooled:
    case step.kind
    of skDone:
      # [G447] Every piece is handed on: the worker gives the digest once they are
      # written.
      if not e.fetching(job.request) or job.id notin e.spools:
        e.unspool(job.id, cmds)
        e.supplyTo(
          job.request,
          job.source,
          Inspection(kind: ikUnavailable, reason: "the archive was not spooled"),
          cmds,
        )
        return
      if not e.spools.getOrDefault(job.id).created:
        e.append(job.id, "", cmds) # an empty archive: its file still exists
      e.spools.mgetOrPut(job.id, Spool()).phase = spFinishing
      cmds.work(WorkerJob(kind: wjFinish, file: job.id))
    of skUnavailable:
      e.unspool(job.id, cmds)
      e.supplyTo(
        job.request,
        job.source,
        Inspection(kind: ikUnavailable, reason: step.reason),
        cmds,
      )
    else:
      discard
    return
  let d = e.requests.getOrDefault(job.request)
  if d.isNil:
    return
  case step.kind
  of skDone:
    d.supply(job.source, e.cache.inspect(step.bytes, e.input.trust))
  of skUnavailable:
    d.supply(job.source, Inspection(kind: ikUnavailable, reason: step.reason))
  else:
    discard
  e.advanceRequest(job.request, cmds)

# Operations (G449) ------------------------------------------------------------------

func slotOf(k: OperationKind): SlotKind =
  if k == opInspect: slInspection else: slMutation

func slotName(k: SlotKind): string =
  case k
  of slMutation: "mutation"
  of slInspection: "inspection"

proc answer(cmds: var seq[Command], request: uint64, a: sink OperationAnswer) =
  cmds.add(Command(kind: cmAnswer, answerTo: request, answer: a))

func responseOf(v: sink CborValue): OperationAnswer =
  OperationAnswer(kind: oaResponse, response: v)

func encodedOf(bytes: sink string): OperationAnswer =
  OperationAnswer(kind: oaEncoded, encoded: bytes)

func moduleErrorOf(reason: string): OperationAnswer =
  OperationAnswer(kind: oaModuleError, reason: reason)

func oldestHeld(e: Engine): Opt[uint64] =
  for sequence in e.held.keys:
    if result.isNone or sequence < result.get:
      result = Opt.some(sequence)

proc collectDue(e: var Engine, cmds: var seq[Command]) =
  ## [G445 R1, R1.1] What no held snapshot names goes to the worker, one collect at a
  ## time, queued only after the commit or release that allows it. The retired list and
  ## the holds are both on this thread (Fable's check §1.5).
  if e.collecting or e.retired.len == 0:
    return
  let oldest = e.oldestHeld()
  let items = due(e.retired, oldest)
  if items.len == 0:
    return
  var keep: seq[Retired]
  for r in e.retired:
    if oldest.isSome and oldest.get < r.sequence:
      keep.add(r)
  e.retired = keep
  e.collecting = true
  cmds.work(WorkerJob(kind: wjCollect, items: items))

proc releaseSnapshot(e: var Engine, snap: Snapshot, cmds: var seq[Command]) =
  ## [G445 R1] One holder fewer; with none left, what only it named may go.
  if snap.isNil:
    return
  var n = e.held.getOrDefault(snap.sequence) - 1
  if n > 0:
    e.held[snap.sequence] = n
    return
  e.held.del(snap.sequence)
  e.collectDue(cmds)

proc begin(e: var Engine, request: uint64, cmds: var seq[Command])

proc endOperation(
    e: var Engine, request: uint64, outcome: string, cmds: var seq[Command]
) =
  ## [G449] The operation is over (answered, or given up by its caller): the operator's
  ## log has its time and the archive bytes it retrieved (Fable's §4), its snapshot is
  ## released, and its slot goes to the next request. A record it staged that no commit
  ## names is deleted: now if it is staged, when the worker answers if it is staging. A
  ## commit the worker runs lands, and moves the snapshot, all the same.
  var op: Operation
  if not e.operations.pop(request, op):
    return
  if not op.started:
    discard e.slots[op.slot].withdraw(request)
    return
  e.timers.del(op.deadline)
  if op.phase == mpDecoding:
    cmds.work(
      WorkerJob(
        kind: wjAbandon,
        rid: op.pending.rid,
        generation: op.pending.generation,
        newDir: not op.pending.signerOnly,
      )
    )
  # [G446] Its kept archives go. One still written, digested or judged goes when its
  # answer comes, so a late judgment is freed in turns (D1's condition).
  var files: seq[uint64]
  for id, sp in e.spools:
    if sp.request == request and sp.kept:
      files.add(id)
  for id in files:
    e.unspool(id, cmds)
  cmds.log(
    $op.request.kind & " ended after " & $(e.clock() - op.startedMs) & " ms, " &
      $op.bytes & " archive bytes retrieved: " & outcome
  )
  e.releaseSnapshot(op.snap, cmds)
  let next = e.slots[op.slot].finish(request)
  if next.isSome:
    e.begin(next.get, cmds)

proc conclude(
    e: var Engine,
    request: uint64,
    a: sink OperationAnswer,
    outcome: string,
    cmds: var seq[Command],
) =
  cmds.answer(request, a)
  e.endOperation(request, outcome, cmds)

proc fail(e: var Engine, request: uint64, err: PackageError, cmds: var seq[Command]) =
  e.conclude(request, responseOf(errorResult(err)), $err.code, cmds)

proc failModule(e: var Engine, request: uint64, why: string, cmds: var seq[Command]) =
  ## [plan §4.7, PKG-0361, PKG-0470] A result that is not a `package_error`: the
  ## invocation error `MODULE_ERROR`, with fixed text.
  e.conclude(request, moduleErrorOf(why), "MODULE_ERROR: " & why, cmds)

proc failStore(
    e: var Engine,
    request: uint64,
    r: WorkerResult,
    commit: bool,
    cmds: var seq[Command],
) =
  ## [5-5-4; plan §4.3, §4.7, §4.9] A store job's fault, as the caller sees it. Its
  ## detail (paths, system errors) is for the operator's log only (PKG-0360).
  let id =
    if r.hasFaultIdentity:
      $r.faultIdentity & ": "
    else:
      ""
  cmds.log(
    (if commit: "a commit failed: " else: "a staging failed: ") & id & $r.fault & ": " &
      r.failure
  )
  template code(c: PackageErrorCode, msg: string): untyped =
    e.fail(request, packageError(c, id & msg), cmds)

  case r.fault
  of sfSource, sfStopped:
    code(pecPackageUnavailable, "its archive no longer gives the selected package")
  of sfWrite:
    if commit:
      e.failModule(request, "the installed state could not be committed", cmds)
    else:
      code(pecPackageUnavailable, "it could not be written to the installed state")
  of sfEscaped:
    code(pecArtifactIntegrity, "its files escaped their realization root")
  of sfIntegrity:
    code(pecArtifactIntegrity, "retained artifact bytes are absent or changed")
  of sfPaths:
    code(
      pecInvalidPackage, "its paths collide under the installation root's path rules"
    )
  of sfConflict:
    code(pecPackageConflict, "the identity is installed with another commitment")
  of sfAdmission:
    e.failModule(request, "a required result does not fit the admission bound", cmds)
  of sfIndexBound:
    e.failModule(request, "the installed index would pass its bound", cmds)
  of sfDamaged, sfInUse:
    e.failModule(request, "the installed state needs a restart", cmds)

func indexOf(s: Snapshot, identity: PackageIdentity): int =
  for i, r in s.records:
    if r.package.identity == identity:
      return i
  -1

func byRid(s: Snapshot, rid: string): SnapRecord =
  for r in s.records:
    if r.rid == rid:
      return r
  nil

func dependedOn(s: Snapshot, at: int): bool =
  ## [SPEC PM §15 l.1693-1696] Whether another record's recorded dependency closure holds
  ## record `at`'s exact identity and commitment. The walk follows recorded edges; the
  ## store keeps every edge's target installed, so it equals the direct check, and it is
  ## kept anyway (plan §4.6).
  let target = s.records[at].package
  var byIdentity = initTable[string, int]()
  for i, r in s.records:
    byIdentity[r.package.identity.identityKey] = i
  for root in 0 ..< s.records.len:
    if root == at:
      continue
    var seen = initHashSet[int]()
    var stack = @[root]
    seen.incl(root)
    while stack.len > 0:
      let i = stack.pop()
      for edge in s.records[i].package.resolvedDependencies:
        if edge.identity == target.identity and edge.commitment == target.commitment:
          return true
        let j = byIdentity.getOrDefault(edge.identity.identityKey, -1)
        if j >= 0 and j notin seen:
          seen.incl(j)
          stack.add(j)
  false

proc askRetained(e: var Engine, request: uint64, record: int, cmds: var seq[Command]) =
  ## [G448] The worker hashes the record's artifacts in the operation's snapshot, whose
  ## files deferred deletion keeps (§4.2).
  var r: SnapRecord
  e.operations.withValue(request, op):
    r = op.snap.records[record]
  do:
    return
  cmds.work(
    WorkerJob(
      kind: wjRetained,
      request: request,
      record: record,
      base: r.base,
      identity: r.package.identity,
      artifacts: r.artifacts,
    )
  )

proc startResolution(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [G449] The operation's resolution, against the snapshot it holds.
  if e.catalog.inUse.isNone:
    e.fail(request, packageError(pecPackageUnavailable, "no catalog is in use"), cmds)
    return
  var root: RootReference
  var snap: Snapshot
  e.operations.withValue(request, op):
    root = op.request.root
    snap = op.snap
  e.requests[request] = initDriver(
    e.catalog.inUse.get.entries,
    e.input.trust,
    e.input.resolverLimits,
    root,
    e.turnWork,
    Opt.some(e.input.limits.operationEntries),
    snap.packages,
  )
  e.advanceRequest(request, cmds)

# Installing (5-5-4) ------------------------------------------------------------------

func installOrder(r: Resolution): seq[SelectedPackage] =
  ## [plan §4.6] The selected packages to install, in dependency order: a post-order walk
  ## from the root over `resolvedDependencies`, children in name byte order [IMPL], the
  ## root last. Installed ones are skipped.
  var at = initTable[string, int]()
  for i, p in r.packages:
    at[p.identity.identityKey] = i
  let rootAt = at.getOrDefault(r.root.identityKey, -1)
  doAssert rootAt >= 0, "the resolution selects its root"
  var children = newSeq[seq[int]](r.packages.len)
  for i, p in r.packages:
    for d in p.resolvedDependencies:
      let j = at.getOrDefault(d.identity.identityKey, -1)
      if j >= 0:
        children[i].add(j)
    children[i].sort(
      proc(a, b: int): int =
        cmp(r.packages[a].identity.package, r.packages[b].identity.package)
    )
  var seen = initHashSet[int]()
  seen.incl(rootAt)
  var stack = @[(rootAt, 0)]
  while stack.len > 0:
    let (i, k) = stack[^1]
    if k < children[i].len:
      stack[^1][1] = k + 1
      let j = children[i][k]
      if j notin seen:
        seen.incl(j)
        stack.add((j, 0))
    else:
      discard stack.pop()
      if not r.packages[i].installed:
        result.add(r.packages[i])

func keptFile(e: Engine, request: uint64, p: SelectedPackage): Opt[uint64] =
  ## [G446] The operation's kept archive judged to give `p`, from `p`'s selected source.
  if p.source.isNone:
    return
  for id, sp in e.spools:
    if sp.request == request and sp.kept and sp.judged and sp.identity == p.identity and
        sp.commitment == p.commitment and sp.source == p.source.get:
      return Opt.some(id)

proc replyRecord(
    e: var Engine, request: uint64, r: SnapRecord, inspect: bool, cmds: var seq[Command]
) =
  ## [Fable's check §4] A committed record's response, encoded by the worker from its
  ## directory: `{installed}`, or `{inspection}`.
  e.operations.withValue(request, op):
    op.phase = mpReplying
  cmds.work(
    WorkerJob(
      kind: wjReply,
      request: request,
      rid: r.rid,
      generation: r.generation,
      identity: r.package.identity,
      inspect: inspect,
    )
  )

proc refetch(e: var Engine, request: uint64, p: SelectedPackage, cmds: var seq[Command])

proc stageNext(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [plan §4.6] The next package in dependency order: its kept archive judged again and
  ## its record staged on the worker. An evicted archive is fetched again first (G446).
  var sel: SelectedPackage
  var isRoot = false
  e.operations.withValue(request, op):
    doAssert op.queue.len > 0
    sel = op.queue[0]
    isRoot = op.queue.len == 1
  do:
    return
  let f = e.keptFile(request, sel)
  if f.isNone:
    e.refetch(request, sel, cmds)
    return
  when defined(posix):
    let rid = newRecordId().valueOr:
      cmds.log("a record id could not be drawn: " & error)
      e.failModule(request, "the installed state could not be written", cmds)
      return
  else:
    let rid = ""
  let sp = e.spools.getOrDefault(f.get)
  e.operations.withValue(request, op):
    op.pending =
      Pending(selected: sel, signer: sp.signer, rid: rid, root: isRoot, file: f.get)
    op.phase = mpStaging
  cmds.work(
    WorkerJob(
      kind: wjStage,
      request: request,
      file: f.get,
      source: sel.source.get.sourceBytes,
      edges: sel.resolvedDependencies,
      rid: rid,
      identity: sel.identity,
      commitment: sel.commitment,
      signer: sp.signer,
      variant: sp.variant,
      digest: sp.digest,
      reply: isRoot,
    )
  )

proc commitPending(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [G445; plan §4.6] The staged record's commit. What the snapshot becomes is kept by
  ## request, apart from the operation: a commit that lands after a cancel still moves it.
  ## The root's commit is the operation's last: neither the deadline nor a cancel applies.
  var job = WorkerJob(kind: wjCommit, request: request)
  var cp: CommitPending
  e.operations.withValue(request, op):
    template p(): untyped =
      op.pending

    job.add =
      @[IndexEntry(rid: p.rid, generation: p.generation, identity: p.selected.identity)]
    if p.root and op.dropRid.len > 0:
      job.drop = @[op.dropRid]
    cp.drop = job.drop
    cp.rid = p.rid
    cp.generation = p.generation
    cp.newDir = not p.signerOnly
    if p.signerOnly:
      let cur = e.snapshot.byRid(p.rid)
      doAssert not cur.isNil, "a signer replacement's record is committed"
      var pk = cur.package
      pk.signer = p.signer
      cp.add = Opt.some(
        SnapRecord(
          package: pk,
          rid: p.rid,
          generation: p.generation,
          base: cur.base,
          artifacts: cur.artifacts,
        )
      )
    else:
      cp.add = Opt.some(
        SnapRecord(
          package: InstalledPackage(
            identity: p.selected.identity,
            commitment: p.selected.commitment,
            signer: p.signer,
            source: p.selected.source.get,
            modules: move p.decoded,
            dependencies: move p.dependencies,
            resolvedDependencies: p.selected.resolvedDependencies,
          ),
          rid: p.rid,
          generation: p.generation,
          base: p.base,
          artifacts: move p.artifacts,
        )
      )
    if p.root:
      op.lastCommit = true
    op.phase = mpCommitting
  do:
    return
  e.committing[request] = cp
  cmds.work(job)

proc alreadyInstalled(
    e: var Engine,
    request: uint64,
    root: SelectedPackage,
    cur: SnapRecord,
    cmds: var seq[Command],
) =
  ## [plan §4.6 install 3] Success with the current record and no duplicate. When the
  ## resolution selected a source for the root and its verified signer is another
  ## accepted `package_signer`, the record's next generation retains it (PKG-0608, 0609; C5).
  let f = e.keptFile(request, root)
  if f.isSome:
    let sp = e.spools.getOrDefault(f.get)
    if sp.signer != cur.package.signer:
      e.operations.withValue(request, op):
        op.pending = Pending(
          selected: root,
          signerOnly: true,
          signer: sp.signer,
          rid: cur.rid,
          generation: cur.generation,
          root: true,
          base: cur.base,
        )
        op.phase = mpStaging
      cmds.work(
        WorkerJob(
          kind: wjStageSigner,
          request: request,
          rid: cur.rid,
          generation: cur.generation,
          identity: cur.package.identity,
          signer: sp.signer,
          reply: true,
        )
      )
      return
  e.replyRecord(request, cur, inspect = false, cmds)

func rootOf(r: Resolution): SelectedPackage =
  for p in r.packages:
    if p.identity == r.root:
      return p

proc inspected(
    e: var Engine, request: uint64, r: sink Resolution, cmds: var seq[Command]
) =
  ## [SPEC PM §15 l.1667-1673] The root's `{inspection}`: the worker encoded it when it
  ## judged the root's archive, or reads it from the installed record.
  let root = r.rootOf
  var reply: string
  var snap: Snapshot
  e.operations.withValue(request, op):
    reply = op.inspections.getOrDefault(judgedKey(root.identity, root.commitment))
    snap = op.snap
  do:
    return
  if reply.len > 0:
    e.conclude(request, encodedOf(reply), "inspected", cmds)
    return
  let at = snap.indexOf(root.identity)
  if root.installed and at >= 0:
    e.replyRecord(request, snap.records[at], inspect = true, cmds)
    return
  cmds.log("inspect_package: no inspection record of " & $root.identity & " was kept")
  e.failModule(request, "the inspection record is not available", cmds)

proc install(
    e: var Engine, request: uint64, r: sink Resolution, cmds: var seq[Command]
) =
  ## [SPEC PM §15 l.1675-1691; plan §4.6] Root conflict, already installed, or each
  ## selected package not installed, staged and committed on its own in dependency order,
  ## the root last. A failure stops there: committed dependencies stay (PKG-0395 to 0398).
  when not defined(posix):
    e.failModule(request, "the installed state is POSIX only", cmds)
    return
  let root = r.rootOf
  var snap: Snapshot
  e.operations.withValue(request, op):
    snap = op.snap
  do:
    return
  let at = snap.indexOf(root.identity)
  if at >= 0 and snap.records[at].package.commitment != root.commitment:
    e.fail(
      request,
      packageError(
        pecPackageConflict, $root.identity & " is installed with another commitment"
      ),
      cmds,
    )
    return
  if root.installed and at >= 0:
    e.alreadyInstalled(request, root, snap.records[at], cmds)
    return
  e.operations.withValue(request, op):
    op.queue = installOrder(r)
  e.stageNext(request, cmds)

proc update(
    e: var Engine, request: uint64, r: sink Resolution, cmds: var seq[Command]
) =
  ## [SPEC PM §15 l.1701-1719; plan §4.6] No newer version: the current record. A target
  ## installed with another commitment: `package-conflict`; with the same one, one commit
  ## drops the current root when the recorded edges equal the new ones (PKG-0535, 0537),
  ## else `dependency-unavailable` (PKG-0536). Otherwise the dependencies install as in
  ## install, and the target's commit swaps it for the current root (PKG-0404, 0405,
  ## 0408). Any failure keeps the current root (PKG-0407).
  when not defined(posix):
    e.failModule(request, "the installed state is POSIX only", cmds)
    return
  var snap: Snapshot
  var current: PackageIdentity
  e.operations.withValue(request, op):
    snap = op.snap
    current = op.request.root.newerThan.get
  do:
    return
  let curAt = snap.indexOf(current)
  doAssert curAt >= 0, "the resolver answers package-not-installed first"
  if r.unchanged:
    e.replyRecord(request, snap.records[curAt], inspect = false, cmds)
    return
  let root = r.rootOf
  let at = snap.indexOf(root.identity)
  if at >= 0:
    let target = snap.records[at]
    if target.package.commitment != root.commitment:
      e.fail(
        request,
        packageError(
          pecPackageConflict, $root.identity & " is installed with another commitment"
        ),
        cmds,
      )
      return
    if target.package.resolvedDependencies != root.resolvedDependencies:
      e.fail(
        request,
        packageError(
          pecDependencyUnavailable,
          "the installed " & $root.identity &
            " records other dependencies than the ones selected now",
        ),
        cmds,
      )
      return
    let drop = @[snap.records[curAt].rid]
    e.committing[request] = CommitPending(drop: drop, replyAfter: Opt.some(target))
    e.operations.withValue(request, op):
      op.lastCommit = true
      op.phase = mpCommitting
    cmds.work(WorkerJob(kind: wjCommit, request: request, drop: drop))
    return
  e.operations.withValue(request, op):
    op.dropRid = snap.records[curAt].rid
    op.queue = installOrder(r)
  e.stageNext(request, cmds)

proc commitRemove(e: var Engine, request: uint64, at: int, cmds: var seq[Command]) =
  ## [SPEC PM §15 l.1693-1699] One commit drops the record; its directory is retired.
  var rid: string
  e.operations.withValue(request, op):
    rid = op.snap.records[at].rid
    op.lastCommit = true
    op.phase = mpCommitting
  do:
    return
  e.committing[request] = CommitPending(drop: @[rid])
  cmds.work(WorkerJob(kind: wjCommit, request: request, drop: @[rid]))

proc beginRemove(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [SPEC PM §15 l.1693-1699] No resolution: an absent identity succeeds with `{}`; one
  ## another record depends on is `package-in-use`; otherwise one commit drops it.
  let op = e.operations.getOrDefault(request)
  let at = op.snap.indexOf(op.request.identity)
  if at < 0:
    e.conclude(request, responseOf(removedResult()), "not installed", cmds)
    return
  if op.snap.dependedOn(at):
    e.fail(
      request,
      packageError(pecPackageInUse, "another installed package depends on it"),
      cmds,
    )
    return
  e.commitRemove(request, at, cmds)

proc beginUpdate(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [SPEC PM §15 l.1701-1719] Another record that depends on the exact current package
  ## and commitment is `package-in-use`, checked before resolution (l.1716, l.1067;
  ## [IMPL]). An absent `current` is the resolver's `package-not-installed`.
  let op = e.operations.getOrDefault(request)
  let current = op.request.root.newerThan
  doAssert current.isSome, "an update's root names its current package"
  let at = op.snap.indexOf(current.get)
  if at >= 0 and op.snap.dependedOn(at):
    e.fail(
      request,
      packageError(pecPackageInUse, "another installed package depends on it"),
      cmds,
    )
    return
  e.startResolution(request, cmds)

proc begin(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [G449] The request takes its slot: it holds the current snapshot, and its
  ## `operation_deadline_ms` starts now, not when it was queued (§4.13).
  var kind: OperationKind
  e.operations.withValue(request, op):
    op.started = true
    op.startedMs = e.clock()
    op.snap = e.snapshot
    kind = op.request.kind
  do:
    return
  e.held[e.snapshot.sequence] = e.held.getOrDefault(e.snapshot.sequence) + 1
  let deadline = e.timer(
    cmds,
    TimerTarget(kind: tkDeadline, job: request),
    e.input.limits.operationDeadlineMs,
  )
  e.operations.withValue(request, op):
    op.deadline = deadline
  case kind
  of opRemove:
    e.beginRemove(request, cmds)
  of opUpdate:
    e.beginUpdate(request, cmds)
  of opInspect, opInstall:
    e.startResolution(request, cmds)

proc dropRun(e: var Engine, request: uint64, cancelCall: bool, cmds: var seq[Command]) =
  ## [G455; Fable F3] The operation takes no more turns: its run is freed by later turns,
  ## its retrievals queued behind another's or waiting for the share are dropped, and one
  ## that has started ends as it would, its answer ignored and its spool file deleted
  ## (G447). [G449] `cancelCall`: that one's outstanding call is cancelled too.
  var d: Driver
  if e.requests.pop(request, d):
    e.retire(d, cmds)
  for b in e.bindings.mitems:
    var i = b.jobs.high
    while i >= 1:
      if not b.jobs[i].catalog and b.jobs[i].request == request:
        b.jobs.delete(i)
      dec i
  for bi in 0 ..< e.bindings.len:
    if e.bindings[bi].jobs.len == 0 or e.bindings[bi].jobs[0].catalog or
        e.bindings[bi].jobs[0].request != request:
      continue
    if e.bindings[bi].jobs[0].wait == jwShare:
      e.bindings[bi].jobs[0].wait = jwNone
      e.apply(
        bi,
        FetchStep(kind: skUnavailable, reason: "the operation is cancelled"),
        jwNone,
        cmds,
      )
    elif cancelCall and e.bindings[bi].jobs[0].wait == jwCall:
      cmds.add(Command(kind: cmCancelCall, cancelled: e.bindings[bi].jobs[0].call))

proc expire(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [G449; plan §4.13] The operation's deadline: `package-unavailable` (PM l.1308,
  ## l.1495), the cancel path, and its outstanding call cancelled rather than left to run
  ## out `read_deadline_ms`. The caller's message does not state the value (l.1514);
  ## the operator's log does. An operation whose last commit has begun is exempt.
  var exempt = false
  e.operations.withValue(request, op):
    exempt = op.lastCommit
  if exempt:
    return
  cmds.log(
    "a root operation stopped at the operation deadline operation_deadline_ms (" &
      $e.input.limits.operationDeadlineMs & ")"
  )
  e.dropRun(request, cancelCall = true, cmds)
  e.fail(
    request,
    packageError(pecPackageUnavailable, "the operation's time bound was reached"),
    cmds,
  )

proc resolved(
    e: var Engine,
    request: uint64,
    outcome: sink Result[Resolution, PackageError],
    cmds: var seq[Command],
) =
  ## [G449] The operation's resolution ended.
  if outcome.isErr:
    e.fail(request, outcome.error, cmds)
    return
  let kind = e.operations.getOrDefault(request).request.kind
  case kind
  of opInspect:
    e.inspected(request, move outcome.get, cmds)
  of opInstall:
    e.install(request, move outcome.get, cmds)
  of opUpdate:
    e.update(request, move outcome.get, cmds)
  of opRemove:
    raiseAssert "a removal does not resolve"

proc refetch(
    e: var Engine, request: uint64, p: SelectedPackage, cmds: var seq[Command]
) =
  ## [G446; plan §4.3] An archive the budget deleted is fetched again from its selected
  ## source, into the operation's budget; it must have the digest it was judged by.
  let bi = e.index(p.source.get.storage)
  if bi < 0:
    e.refetchFailed(request, "its source names no configured binding", cmds)
    return
  e.operations.withValue(request, op):
    op.phase = mpRefetching
  let job = Job(
    id: e.nextId(),
    request: request,
    source: p.source.get,
    fetch: initRetrieval(
      p.source.get.objectLocator,
      e.input.limits.archiveBytes,
      e.input.limits.readDeadlineMs,
      spooled = true,
    ),
    refetch: true,
  )
  e.enqueue(bi, job, cmds)

proc refetchFailed(
    e: var Engine, request: uint64, reason: string, cmds: var seq[Command]
) =
  var live = false
  var identity: PackageIdentity
  e.operations.withValue(request, op):
    live = op.phase == mpRefetching
    if op.queue.len > 0:
      identity = op.queue[0].identity
  if not live:
    return
  cmds.log("an evicted archive could not be fetched again: " & reason)
  e.fail(
    request,
    packageError(pecPackageUnavailable, $identity & ": its archive is not available"),
    cmds,
  )

proc refetched(
    e: var Engine,
    file: uint64,
    digest: Blake3Digest,
    failure: string,
    cmds: var seq[Command],
) =
  ## [G446] The evicted archive is spooled again: with the digest it was judged by it is
  ## kept, with those facts, and staged; another digest is `package-unavailable` (PM §8
  ## l.1094).
  let request = e.spools.getOrDefault(file).request
  var ev: Opt[Evicted]
  var live = false
  e.operations.withValue(request, op):
    live = op.phase == mpRefetching
    if live and op.queue.len > 0:
      let p = op.queue[0]
      for x in op.evicted:
        if x.judged and x.identity == p.identity and x.commitment == p.commitment and
            x.source == p.source.get:
          ev = Opt.some(x)
  if not live:
    e.unspool(file, cmds)
    return
  if failure.len > 0:
    cmds.log(spoolFailed(failure))
    e.unspool(file, cmds)
    e.refetchFailed(request, "the archive could not be spooled", cmds)
    return
  if ev.isNone or ev.get.digest != digest:
    e.unspool(file, cmds)
    e.refetchFailed(request, "fetched again, the archive has another digest", cmds)
    return
  let x = ev.get
  e.spools.withValue(file, sp):
    sp.digest = digest
    sp.kept = true
    sp.eligible = true
  e.judged(file, x.identity, x.commitment, x.signer, x.variant)
  e.operations.withValue(request, op):
    op.phase = mpIdle
  e.stageNext(request, cmds)

proc stagedTurn(e: var Engine, request: uint64, cmds: var seq[Command]) =
  ## [G447; Fable's check §3] One turn of the staged record's decoding: a slice of its
  ## manifest's dependencies (D1's turns), or one selected module declaration, the stated
  ## hold. The bytes are the worker's own encoding: a decode that fails is a Defect.
  var done = false
  e.operations.withValue(request, op):
    if op.phase != mpDecoding:
      return
    template p(): untyped =
      op.pending

    if not p.depsDone:
      var budget = DecodeTurnUnits
      if p.deps.decodeSome(budget):
        p.depsDone = true
        p.dependencies = p.deps.take()
    elif p.decoded.len < p.modules.len:
      let k = p.decoded.len
      let v = decodeCbor(p.modules[k])
      doAssert v.isOk, "the worker's encoding of a module declaration"
      p.decoded.add(moduleDeclaration(v.get))
      p.modules[k] = ""
    done = p.depsDone and p.decoded.len == p.modules.len
  do:
    return
  if done:
    e.commitPending(request, cmds)
  else:
    cmds.add(Command(kind: cmContinue, operation: request))

proc onStaged(e: var Engine, r: sink WorkerResult, cmds: var seq[Command]) =
  ## [5-5-4] A staging's answer. One whose operation went is deleted: nothing names it.
  var live = false
  e.operations.withValue(r.request, op):
    live = op.phase == mpStaging and op.pending.rid == r.rid
  if not live:
    if not r.hasFault:
      cmds.work(
        WorkerJob(
          kind: wjAbandon, rid: r.rid, generation: r.generation, newDir: r.file != 0
        )
      )
    return
  if r.hasFault:
    e.failStore(r.request, r, commit = false, cmds)
    return
  var signerOnly = false
  e.operations.withValue(r.request, op):
    template p(): untyped =
      op.pending

    p.generation = r.generation
    signerOnly = p.signerOnly
    if p.root:
      op.reply = move r.reply
    if not signerOnly:
      p.base = r.base
      p.modules = move r.modules
      p.artifacts = move r.artifacts
      p.deps = initDecoding(move r.staged)
      op.phase = mpDecoding
  if signerOnly:
    e.commitPending(r.request, cmds)
  else:
    cmds.add(Command(kind: cmContinue, operation: r.request))

proc onCommitted(e: var Engine, r: sink WorkerResult, cmds: var seq[Command]) =
  ## [G445] A commit's answer. Landed: the snapshot moves (Fable's check §1: the module
  ## thread asserts the sequence is its own plus one), what the index no longer names is
  ## retired, and the package's spool file goes (plan §4.3). Failed: nothing is committed,
  ## so the staged record is deleted, unless the index write's outcome is unknown, when
  ## nothing is (the worker refuses every later write until a restart).
  var cp: CommitPending
  discard e.committing.pop(r.request, cp)
  if r.hasFault:
    if r.fault != sfWrite and cp.add.isSome:
      cmds.work(
        WorkerJob(
          kind: wjAbandon, rid: cp.rid, generation: cp.generation, newDir: cp.newDir
        )
      )
    if r.request in e.operations:
      e.failStore(r.request, r, commit = true, cmds)
    else:
      cmds.log(
        "a commit failed after its operation ended: " & $r.fault & ": " & r.failure
      )
    return
  doAssert r.sequence == e.snapshot.sequence + 1, "a commit answers the next sequence"
  e.snapshot = e.snapshot.next(r.sequence, cp.add, cp.drop)
  for it in r.retired:
    e.retired.add(Retired(sequence: r.sequence, item: it))
  inc e.installedChanges
  var file = 0'u64
  var kind: OperationKind
  var last = false
  var reply: string
  e.operations.withValue(r.request, op):
    file = op.pending.file
    kind = op.request.kind
    last = op.lastCommit
    if op.queue.len > 0:
      op.queue.delete(0)
    op.pending = Pending()
    op.phase = mpIdle
    if last:
      reply = move op.reply
  do:
    e.collectDue(cmds)
    return
  if file != 0:
    e.unspool(file, cmds)
  e.collectDue(cmds)
  if cp.replyAfter.isSome:
    e.replyRecord(r.request, cp.replyAfter.get, inspect = false, cmds)
  elif kind == opRemove:
    e.conclude(r.request, responseOf(removedResult()), "removed", cmds)
  elif last:
    e.conclude(r.request, encodedOf(reply), "committed", cmds)
  else:
    e.stageNext(r.request, cmds)

proc onReply(e: var Engine, r: sink WorkerResult, cmds: var seq[Command]) =
  var snap: Snapshot
  if e.queries.pop(r.request, snap):
    # [5-5-4] a query's answer: its snapshot released after it
    if r.failure.len > 0:
      cmds.log("get_runtime_handoff: " & r.failure)
    if r.hasFault:
      cmds.answer(r.request, moduleErrorOf("the installed state needs a restart"))
    else:
      cmds.answer(r.request, encodedOf(move r.reply))
    e.releaseSnapshot(snap, cmds)
    return
  var live = false
  e.operations.withValue(r.request, op):
    live = op.phase == mpReplying
  if not live:
    return
  if r.hasFault:
    e.failStore(r.request, r, commit = false, cmds)
    return
  e.conclude(r.request, encodedOf(move r.reply), "answered", cmds)

proc onCollected(e: var Engine, r: sink WorkerResult, cmds: var seq[Command]) =
  ## [R1] A collect's answer: what failed stays retired for the next one, and what the
  ## index names, which a collect never deletes, is reported (Fable's check §1.4).
  e.collecting = false
  for f in r.collected.failures:
    cmds.log("a retired directory could not be deleted: " & f)
  for it in r.collected.failed:
    e.retired.add(Retired(sequence: 0, item: it))
  for it in r.collected.refused:
    cmds.log(
      "a collect was asked to delete " & it.rid & " generation " & $it.generation &
        ", which the index names; refused"
    )
  e.collectDue(cmds)

# Entry points -----------------------------------------------------------------------

proc submit*(e: var Engine, request: uint64, op: sink OperationRequest): seq[Command] =
  ## [G449] One operation; its answer is a later `cmAnswer`, or one now. It runs in its
  ## slot (mutations one at a time, inspections one at a time beside them), waits behind
  ## the running one, or, with `MaxQueuedOperations` waiting already, is refused at once
  ## with `MODULE_ERROR`, before any work and with no snapshot taken (§4.13). A request id
  ## in use or reserved is `invalid-request`.
  if e.stopped:
    return
  let reserved = request == ReleaseOperation or request == DecodeOperation
  if reserved or request in e.requests or request in e.operations or request in e.queries:
    result.answer(
      request,
      responseOf(
        errorResult(
          pecInvalidRequest,
          if reserved: "the request id is reserved" else: "the request id is in use",
        )
      ),
    )
    return
  let slot = slotOf(op.kind)
  case e.slots[slot].admit(request)
  of adFull:
    result.answer(
      request,
      OperationAnswer(
        kind: oaModuleError,
        reason: "the Package Manager's " & slot.slotName & " queue is full",
      ),
    )
  of adQueued:
    e.operations[request] = Operation(request: op, slot: slot)
  of adRun:
    e.operations[request] = Operation(request: op, slot: slot)
    e.begin(request, result)

proc handoff*(
    e: var Engine, request: uint64, identity: PackageIdentity, module: string
): seq[Command] =
  ## [SPEC PM §12; G451; plan §4.6] `get_runtime_handoff`: the module's handoff from the
  ## current snapshot, built on the worker from the record's directory. A query: it takes
  ## no slot and does not queue, and holds the snapshot it read until its answer, so the
  ## record's files stay (R1).
  if e.stopped:
    return
  let reserved = request == ReleaseOperation or request == DecodeOperation
  if reserved or request in e.requests or request in e.operations or request in e.queries:
    result.answer(
      request,
      responseOf(
        errorResult(
          pecInvalidRequest,
          if reserved: "the request id is reserved" else: "the request id is in use",
        )
      ),
    )
    return
  let at = e.snapshot.indexOf(identity)
  if at < 0:
    result.answer(
      request,
      responseOf(errorResult(pecPackageNotInstalled, $identity & " is not installed")),
    )
    return
  when not defined(posix):
    result.answer(request, moduleErrorOf("the installed state is POSIX only"))
    return
  let r = e.snapshot.records[at]
  e.queries[request] = e.snapshot
  e.held[e.snapshot.sequence] = e.held.getOrDefault(e.snapshot.sequence) + 1
  result.work(
    WorkerJob(
      kind: wjHandoff,
      request: request,
      rid: r.rid,
      generation: r.generation,
      identity: identity,
      module: module,
    )
  )

proc start*(e: var Engine): seq[Command] =
  ## On start: a route for every binding.
  if e.started or e.stopped:
    return
  e.started = true
  for bi in 0 ..< e.bindings.len:
    e.establish(bi, result)

proc resolve*(e: var Engine, request: uint64, root: RootReference): seq[Command] =
  ## [G405] One root operation; its outcome is a later `cmReply`. A request id
  ## in use, `ReleaseOperation`'s or `DecodeOperation`'s, is refused
  ## `invalid-request`.
  if e.stopped:
    return
  let reserved = request == ReleaseOperation or request == DecodeOperation
  if reserved or request in e.requests:
    result.add(
      Command(
        kind: cmReply,
        request: request,
        outcome: Result[Resolution, PackageError].err(
          packageError(
            pecInvalidRequest,
            if reserved: "the request id is reserved" else: "the request id is in use",
          )
        ),
      )
    )
    return
  if e.catalog.inUse.isNone:
    result.add(
      Command(
        kind: cmReply,
        request: request,
        outcome: Result[Resolution, PackageError].err(
          packageError(pecPackageUnavailable, "no catalog is in use")
        ),
      )
    )
    return
  e.requests[request] = initDriver(
    e.catalog.inUse.get.entries,
    e.input.trust,
    e.input.resolverLimits,
    root,
    e.turnWork,
    Opt.some(e.input.limits.operationEntries),
  )
  e.advanceRequest(request, result)

proc onAnswer(e: var Engine, call: uint64, a: Answer, cmds: var seq[Command]) =
  if call notin e.calls:
    return # late: its deadline passed, or its job ended
  let (bi, jobId, generation) = e.calls.getOrDefault(call)
  e.calls.del(call)
  if e.bindings[bi].jobs.len == 0 or e.bindings[bi].jobs[0].id != jobId:
    return
  e.bindings[bi].jobs[0].call = 0
  e.bindings[bi].jobs[0].timer = 0
  e.bindings[bi].jobs[0].wait = jwNone
  var waitFor = jwNone
  if a.kind == akRouteLost:
    waitFor = jwRoute
  elif a.kind == akFailure and a.code == fcNotReady:
    waitFor = jwReady
    e.bindings[bi].readiness = Opt.none(Readiness)
  let stat = e.bindings[bi].jobs[0].fetch.pending.kind == ckStat
  let step = e.bindings[bi].jobs[0].fetch.onAnswer(a)
  template j(): untyped =
    e.bindings[bi].jobs[0]

  if not stat and a.kind == akValue and not j.catalog:
    e.operations.withValue(j.request, op):
      op.bytes += int64(a.data.len) # [G449] for the operator's log

  if j.fetch.spooled and step.kind in {skCall, skDone}:
    if stat and e.isMutation(j.request):
      # [G446] A mutation's archive: its budget, made room for by deleting what it may.
      let size = int64(j.fetch.size.get(0))
      e.makeRoom(j.request, size, cmds)
      e.mutationUsed += size
      e.spools[j.id] = Spool(
        request: j.request,
        source: j.source,
        binding: bi,
        reserved: size,
        mutation: true,
        refetch: j.refetch,
      )
    elif stat:
      # [G446] The size is known: the archive's part of the share, or a wait for it.
      let size = int64(j.fetch.size.get(0))
      if e.shareWaiters.len > 0 or not e.fits(size):
        j.wait = jwShare
        e.shareWaiters.add((bi, j.id))
        return
      e.reserve(bi, size)
    elif j.fetch.hasChunk and j.id in e.spools:
      # [G447] The piece goes to the worker, never kept here.
      e.append(j.id, j.fetch.takeChunk(), cmds)
  e.apply(bi, step, waitFor, cmds)
  if a.kind == akRouteLost:
    if e.bindings[bi].generation == generation:
      # The route the call went over is the binding's: it is lost. A renewal or
      # a new establishment resumes the waiting job, or a refusal fails it.
      e.lose(bi, cmds)
    elif e.bindings[bi].usable:
      # The route was already replaced: issue the call again at once.
      e.resumeRoute(bi, cmds)

proc onTimer(e: var Engine, id: uint64, cmds: var seq[Command]) =
  if id notin e.timers:
    return
  let t = e.timers.getOrDefault(id)
  e.timers.del(id)
  case t.kind
  of tkRoute:
    if e.bindings[t.binding].state == rsBackoff:
      e.establish(t.binding, cmds)
  of tkAcquire:
    if e.acquireTimer == id:
      e.acquireTimer = 0
      e.acquire(cmds)
  of tkJob:
    let bi = t.binding
    if e.bindings[bi].jobs.len == 0 or e.bindings[bi].jobs[0].id != t.job or
        e.bindings[bi].jobs[0].timer != id:
      return # stale
    e.bindings[bi].jobs[0].timer = 0
    let wait = e.bindings[bi].jobs[0].wait
    e.bindings[bi].jobs[0].wait = jwNone
    case wait
    of jwCall:
      e.calls.del(e.bindings[bi].jobs[0].call)
      e.bindings[bi].jobs[0].call = 0
      let step = e.bindings[bi].jobs[0].fetch.onDeadline()
      e.apply(bi, step, jwNone, cmds)
    of jwRoute, jwReady:
      let step = e.bindings[bi].jobs[0].fetch.onWaitExpired()
      e.apply(bi, step, jwNone, cmds)
    of jwBackoff:
      let step = e.bindings[bi].jobs[0].fetch.resume()
      e.apply(bi, step, jwNone, cmds)
    of jwNone, jwSpool, jwShare:
      discard
  of tkDeadline:
    let request = t.job
    let op = e.operations.getOrDefault(request)
    if request notin e.operations or not op.started or op.deadline != id or op.lastCommit:
      return
    e.expire(request, cmds)

proc handle*(e: var Engine, ev: sink Event): seq[Command] =
  ## One event; nothing after `stop`.
  if e.stopped or not e.started:
    return
  case ev.kind
  of evEstablished, evRenewed:
    e.onEstablished(ev, result)
  of evRouteLost:
    let bi = e.index(ev.lostBinding)
    if bi >= 0 and e.bindings[bi].route == ev.lostRoute:
      e.lose(bi, result)
  of evReadiness:
    let bi = e.index(ev.readyBinding)
    if bi < 0 or not e.bindings[bi].usable:
      return
    e.bindings[bi].readiness = Opt.some(ev.readiness)
    if ev.readiness == rdReady:
      e.resumeReady(bi, result)
      if bi == e.catalogBinding:
        e.acquire(result)
  of evAnswer:
    e.onAnswer(ev.call, ev.reply, result)
  of evTimer:
    e.onTimer(ev.timer, result)
  of evWorked:
    e.onWorked(move ev.worked, result)
  of evContinue:
    if ev.continued == ReleaseOperation:
      e.releaseTurn(result)
    elif ev.continued == DecodeOperation:
      e.dropTurn(result)
    elif ev.continued in e.requests:
      e.advanceRequest(ev.continued, result)
    else:
      # [G455; Fable F3] An operation that is gone (done, cancelled) is not
      # advanced. [5-5-4] One whose staged record decodes takes its next turn.
      e.stagedTurn(ev.continued, result)

proc cancel*(e: var Engine, request: uint64): seq[Command] =
  ## [G455; Fable F3] The caller gave the operation up: it takes no more turns
  ## and nothing answers it; its run is freed by later turns. Its retrieval, if
  ## one is queued behind another or waits for the share (G446), is dropped
  ## too; one that has started ends as it would, its answer is ignored, and its
  ## spool file is deleted (G447). A later `evContinue` for it is ignored.
  ## [G449] An operation waiting for its slot leaves the queue without running; a running
  ## one ends here, its slot passing on (R2); one whose last commit has begun is not
  ## cancelled: the commit completes (Fable's §4).
  if e.stopped:
    return
  var snap: Snapshot
  if e.queries.pop(request, snap):
    e.releaseSnapshot(snap, result)
    return
  if request in e.operations:
    let op = e.operations.getOrDefault(request)
    if not op.started:
      e.endOperation(request, "cancelled while waiting", result)
      return
    if op.lastCommit:
      return
    e.dropRun(request, cancelCall = false, result)
    e.endOperation(request, "cancelled", result)
    return
  if request notin e.requests:
    return
  e.dropRun(request, cancelCall = false, result)

proc stop*(e: var Engine): seq[Command] =
  ## `_MODULE_destroy` began: route upkeep, retrieval and resolution stop, and
  ## no command follows (G437). Each root operation still running, sliced or
  ## waiting for a retrieval, is answered `package-unavailable` here, in
  ## request order, and its driver dropped (G405, G455); so are the runs being
  ## released, at once, since the module is going away.
  if e.stopped:
    return
  e.stopped = true
  for b in e.bindings.mitems:
    b.state = rsStopped
  var pending: seq[uint64]
  for id in e.requests.keys:
    if id notin e.operations:
      pending.add(id)
  pending.sort()
  # [G449] Every operation, running or waiting, is answered too (G405's stop).
  var ops: seq[uint64]
  for id in e.operations.keys:
    ops.add(id)
  for id in e.queries.keys:
    ops.add(id)
  ops.sort()
  for id in ops:
    result.answer(
      id,
      responseOf(errorResult(pecPackageUnavailable, "the Package Manager is stopping")),
    )
  e.operations.clear()
  e.queries.clear()
  for slot in e.slots.mitems:
    discard slot.clear()
  e.held.clear()
  for id in pending:
    result.add(
      Command(
        kind: cmReply,
        request: id,
        outcome: Result[Resolution, PackageError].err(
          packageError(pecPackageUnavailable, "the Package Manager is stopping")
        ),
      )
    )
  e.requests.clear()
  e.releasing.setLen(0)
  e.releaseQueued = false
  # [G447] The shell stops the worker, which deletes the spool files it holds.
  e.spools.clear()
  e.shareWaiters.setLen(0)
  e.shareUsed = 0
  e.dropping.setLen(0)
  e.decodeQueued = false

# Event constructors, for the shell and the tests ------------------------------------

func established*(binding, key, route: string): Event =
  Event(kind: evEstablished, binding: binding, key: key, answer: raReady, route: route)

func establishRefused*(binding, key, reason: string): Event =
  Event(
    kind: evEstablished, binding: binding, key: key, answer: raRefused, reason: reason
  )

func establishLost*(binding, key: string): Event =
  Event(kind: evEstablished, binding: binding, key: key, answer: raLost)

func renewed*(binding, key: string): Event =
  Event(kind: evRenewed, binding: binding, key: key, answer: raReady)

func renewRefused*(binding, key, reason: string): Event =
  Event(kind: evRenewed, binding: binding, key: key, answer: raRefused, reason: reason)

func renewLost*(binding, key: string): Event =
  Event(kind: evRenewed, binding: binding, key: key, answer: raLost)

func routeLost*(binding, route: string): Event =
  Event(kind: evRouteLost, lostBinding: binding, lostRoute: route)

func readinessOf*(binding: string, r: Readiness): Event =
  Event(kind: evReadiness, readyBinding: binding, readiness: r)

func answered*(call: uint64, a: Answer): Event =
  Event(kind: evAnswer, call: call, reply: a)

func fired*(timer: uint64): Event =
  Event(kind: evTimer, timer: timer)

func continued*(operation: uint64): Event =
  Event(kind: evContinue, continued: operation)

func worked*(r: sink WorkerResult): Event =
  Event(kind: evWorked, worked: r)

func sized*(size: uint64): Answer =
  Answer(kind: akValue, size: size)

func dataOf*(data: openArray[byte]): Answer =
  Answer(kind: akValue, data: @data)

func failureOf*(code: FailureCode, detail = ""): Answer =
  Answer(kind: akFailure, code: code, detail: detail)

func invocationError*(error: string): Answer =
  Answer(kind: akError, error: error)

func routeGone*(error = "the route is no longer usable"): Answer =
  Answer(kind: akRouteLost, error: error)

{.pop.}
