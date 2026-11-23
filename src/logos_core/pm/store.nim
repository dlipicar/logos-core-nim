## The installed-state store (Tier 5 step 5-5-2; DECISIONS G444, G445, G446's writing half;
## docs/PACKAGE-MANAGER.md §8, §9; DEPLOYMENT §1, §9, §19; PACKAGE MANAGER §5 l.818-830, §7.1
## l.922-933, §10 l.1176-1195, §15 l.1721-1728). A library over one instance's installation root;
## the worker and the operations that call it are steps 5-5-3 and 5-5-4. POSIX only.
##
## - **Two halves** (5-5-4; DECISIONS G449; Fable's check of the store's thread, design A):
##   `StoreFiles` is what only file work reads (the root, the path rules, the sync mode, the
##   `install/r/` descriptor, the sequence, the index entries, the broken mark), and after the
##   start it is the worker's alone (`handOver`, sent in `wjStart`): its entries are the only
##   copy. `InstalledStore` wraps it for the start, which runs on the module thread at
##   `_MODULE_init`, and for `test_pm_store`; it keeps the lock. The procedures that end in
##   `Files` are the worker's; the module thread holds the snapshot, the holds and the retired
##   list (`engine.nim`).
##
## - **The root** (G444) is `<state_dir>/install/`: `lock` (held for the store's life, so a
##   second writer on the same root is refused: PKG-0487), `index` (the committed set),
##   `r/<rid>/` (one record: `a/<path>` the selected variant's files, `m/manifest.cbor`,
##   `m/manifest.cose` and `m/record.<g>`), and `spool/` (5-5-3's). Directories are 0700, record
##   files 0400. `rid` is 128 bits from the OS random source, never reused.
## - **Path rules** (PM l.924, PKG-0489): `hostPathRules()`, made case-insensitive when a probe in
##   the root finds that `lcn-probe` opens `Lcn-probe`. Every package's paths are checked with
##   them before anything is written.
## - **Staging** writes a record's directory in full and syncs it, before anything names it
##   (PKG-0219): the admission bound first (G452), then the files descriptor-relative
##   (`extract.nim`, PKG-0204), the manifest's signed bytes and `m/record.1`. The files come from
##   the extraction pass over the judged archive's source (`lgx.extractLgx`, step 5-5-2b, G446),
##   each written as it is inflated and checked against its signed hash at its end; a source
##   that no longer gives the judged package is `sfSource`. A failure deletes the directory,
##   which nothing names.
## - **The commit** (PKG-0610) replaces `install/index` with `writeAtomic`. Before it, the staged
##   files are on the medium: Linux from 5.8 on ext4 takes one `syncfs` on the `install/r/`
##   descriptor opened at start (`smSyncfs`); elsewhere each file and each directory is `fsync`ed,
##   ending at `install/r/` (`smEachFile`), and on Darwin the drive flush is `writeAtomic`'s own
##   `F_FULLFSYNC` on the new index. One commit adds, drops or regenerates records; an identity
##   is installed once (PKG-0182).
## - **Retirement** (R1): a directory or a record generation the new index no longer names is
##   retired with that commit's sequence and deleted by `collect` once no holder of an older
##   snapshot remains. The holders are the engine's operations and queries (5-5-4), and
##   `collectFiles` refuses, and reports, an item the index still names.
## - **The start** (`openStore`): the lock, the probe, then the index. No index and an empty `r/`
##   is a fresh root; no index while `r/` holds entries stops the start and deletes nothing (S6).
##   Each named record is read, checked against its signed manifest and its admission bound at
##   the current path (PKG-0471); any failure stops the start, naming the identity (R3). Only
##   then are unnamed directories, generations, `*.tmp` and `spool/` deleted (PKG-0611).
## - **The retained hash** (`checkRetained`, PKG-0181, PKG-0293): each artifact file of a record,
##   opened below `a/` with no link followed, against its signed digest. Nothing rewrites a
##   committed file (PKG-0500).
## - **A test hook** (`-d:lcnTestHooks` only): `LCN_TEST_EXTRACT_PACE_MS` pauses the extraction
##   sink that long for each MiB written, so the hosted tests can stop an instance mid-extraction.

{.push raises: [].}

import std/[algorithm, os, sets, strutils, sysrand, tables]
import results
import logos_sdk/base/[hex, testhooks]
import ../durable
import ../package/[lgx, manifest, records, signing]
import ./[admission, extract, handoff, installed]

when defined(posix):
  import std/posix

export installed, extract, handoff, admission

testHooksMarker("pm_store")

const
  InstallDir* = "install"
  IndexName* = "index"
  RecordsDir* = "r"
  SpoolDir* = "spool"
  ArtifactsDir* = "a"
  MetaDir* = "m"
  ManifestFile* = "manifest.cbor"
  SignatureFile* = "manifest.cose"
  RecordPrefix* = "record."
  ProbeName = "Lcn-probe"
  ProbeFolded = "lcn-probe"
  MaxRecordFileBytes* = 16 * 1024 * 1024
    ## [G445] a record file's bounded read: its record fits the 16 MiB admission bound
  MaxConfigArtifactBytes* = 8 * 1024 * 1024
    ## [SPEC CONFIGURATION; G451] the largest configuration artifact a handoff reads: a
    ## default value (a schema is at most 1 MiB)

type
  SyncMode* = enum
    smEachFile = "fsync on each file and directory"
    smSyncfs = "one syncfs on the installation root's filesystem"

  Installed* = object ## One committed record, as loaded.
    rid*: string
    file*: RecordFile
    manifest*: Manifest
    base*: string ## its absolute `a/` directory, ending in `/`

  Staged* = object
    ## A record directory, or a record's next generation, written and synced; named by nothing
    ## until it is committed.
    rid*: string
    file*: RecordFile
    manifest*: Manifest
    base*: string
    newDir: bool

  CrashPoint* = enum
    ## Test hooks: where a staging or a commit stops as a crash would.
    cpNone
    cpAfterFiles ## the record's files written, not synced
    cpAfterIndexTmp ## the new index written to `index.tmp`, not renamed
    cpAfterRename ## the new index in place, the store's memory not yet changed

  StoreFiles* = object
    ## [G445; Fable's 5-5-4 check §1] The installation root's file half: what only file work
    ## reads. After the start it is the worker's alone (`handOver`), and its index entries are
    ## the only copy in memory. Plain data: it crosses in `wjStart`.
    root*: string ## `<stateDir>/install`
    rules*: PathRules ## the root's path-comparison rules
    syncMode*: SyncMode
    sequence*: uint64 ## commits so far
    entries*: seq[IndexEntry] ## the committed set, in index order
    rFd: cint
    broken: string ## why the store needs a restart: a commit whose outcome is unknown
    when defined(lcnTestHooks):
      crashAt*: CrashPoint

  StagedFiles* = object
    ## A staging's outcome on the file half: a new record directory, or a committed record's
    ## next generation, written and synced.
    rid*: string
    file*: RecordFile
    base*: string ## its `a/` directory
    newDir*: bool

  Committed* = object
    sequence*: uint64 ## the new index's
    retired*: seq[RetiredItem] ## what it no longer names

  InstalledStore* = object
    ## The synchronous store: the start, and `test_pm_store`. Its file half goes to the
    ## worker after the start (`handOver`); the module thread keeps the lock.
    stateDir*: string
    files: StoreFiles
    records*: seq[Installed] ## the committed set, in index order
    notes*: seq[string]
      ## the start's notes for the operator's log: what it deleted and what it could not
    lock: DurableLock
    retired: seq[Retired]

func storeError(
    f: StoreFault, detail: string, identity = Opt.none(PackageIdentity)
): StoreError =
  StoreError(fault: f, identity: identity, detail: detail)

func toStore(e: ExtractError, identity: PackageIdentity): StoreError =
  let f =
    case e.fault
    of efExists: sfEscaped
    of efWrite: sfWrite
    of efRead: sfIntegrity
    of efStopped: sfStopped
  storeError(f, e.detail, Opt.some(identity))

func root*(s: InstalledStore): string =
  s.files.root

func rules*(s: InstalledStore): PathRules =
  s.files.rules

func syncMode*(s: InstalledStore): SyncMode =
  s.files.syncMode

func sequence*(s: InstalledStore): uint64 =
  s.files.sequence

when defined(lcnTestHooks):
  proc `crashAt=`*(s: var InstalledStore, at: CrashPoint) =
    s.files.crashAt = at

  proc rules*(s: var InstalledStore): var PathRules =
    ## A test's change to the root's rules.
    s.files.rules

  proc `syncMode=`*(s: var InstalledStore, m: SyncMode) =
    s.files.syncMode = m

func recordName*(generation: uint64): string =
  RecordPrefix & $generation

func recordDir*(f: StoreFiles, rid: string): string =
  f.root / RecordsDir / rid

func recordDir*(s: InstalledStore, rid: string): string =
  s.files.recordDir(rid)

func baseOf*(root, rid: string): string =
  root / RecordsDir / rid / ArtifactsDir & "/"

func find*(s: InstalledStore, identity: PackageIdentity): Opt[int] =
  ## The committed record of `identity`, by its position in `records`.
  for i, r in s.records:
    if r.file.record.identity == identity:
      return Opt.some(i)
  Opt.none(int)

when defined(posix):
  # The probe and the sync mode ---------------------------------------------------------

  proc probeIgnoresCase(root: string): Result[bool, string] =
    ## [SPEC PM l.924; G444] Whether the root's filesystem finds `lcn-probe` by `Lcn-probe`.
    let a = root / ProbeName
    let b = root / ProbeFolded
    discard posix.unlink(cstring(a))
    discard posix.unlink(cstring(b))
    let fd = posix.open(cstring(a), O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, 0o600)
    if fd < 0:
      return err("cannot create " & a & ": " & $strerror(errno))
    discard posix.close(fd)
    let other = posix.open(cstring(b), O_RDONLY or O_CLOEXEC)
    let folds = other >= 0
    if folds:
      discard posix.close(other)
    if posix.unlink(cstring(a)) != 0:
      return err("cannot remove " & a & ": " & $strerror(errno))
    ok(folds)

  when defined(linux):
    type StatFs {.importc: "struct statfs", header: "<sys/vfs.h>", bycopy.} = object
      f_type: clong

    proc c_fstatfs(
      fd: cint, buf: var StatFs
    ): cint {.importc: "fstatfs", header: "<sys/vfs.h>".}

    const Ext4Magic = 0xEF53 ## ext2, ext3 and ext4

    proc kernelAtLeast(major, minor: int): bool =
      var u: Utsname
      if uname(u) != 0:
        return false
      let release = $cast[cstring](addr u.release)
      let parts = release.split({'.', '-'})
      if parts.len < 2:
        return false
      try:
        let (a, b) = (parseInt(parts[0]), parseInt(parts[1]))
        a > major or (a == major and b >= minor)
      except ValueError:
        false

  proc syncModeOf(rFd: cint): SyncMode =
    ## [G445] `syncfs` where it was measured and reports write errors: Linux from 5.8 on ext4.
    when defined(linux):
      var st: StatFs
      if kernelAtLeast(5, 8) and c_fstatfs(rFd, st) == 0 and st.f_type == Ext4Magic:
        return smSyncfs
    smEachFile

  # Files of the root --------------------------------------------------------------------

  proc newRid(): Result[string, string] =
    var b: array[RidChars div 2, byte]
    if not urandom(b):
      return err("the operating system's random source failed")
    ok(b.toHex.toLowerAscii)

  proc readAll(path: string, maxBytes: int): Result[seq[byte], string] =
    let got = ?readBounded(path, maxBytes)
    if got.isNone:
      return err(path & " is missing")
    ok(got.get)

  proc removeTree(path: string): Result[void, string] =
    ## No directory below the root is ever read-only, so a plain recursive delete works (S4).
    try:
      if dirExists(path):
        removeDir(path)
      elif fileExists(path) or symlinkExists(path):
        removeFile(path)
      ok()
    except CatchableError as e:
      err("cannot delete " & path & ": " & e.msg)

  proc reader*(i: Installed): ArtifactReader =
    ## [G451] The handoff's read of one artifact of `i`: below its `a/`, no link followed, at
    ## most `MaxConfigArtifactBytes`.
    let base = i.base
    result = proc(
        a: InstalledArtifact
    ): Result[seq[byte], string] {.gcsafe, raises: [].} =
      let root = ?openDir(base)
      defer:
        closeFd(root)
      readBelow(root, a.path, MaxConfigArtifactBytes).mapErr(
        proc(e: ExtractError): string =
          e.detail
      )

  proc packageReader(p: ptr LgxPackage): ArtifactReader =
    ## An archive's kept documents, by id: the admission bound before anything is written. The
    ## handoff reads configuration artifacts only, which the reader keeps (G446).
    result = proc(
        a: InstalledArtifact
    ): Result[seq[byte], string] {.gcsafe, raises: [].} =
      if a.id in p[].documents:
        return ok(p[].documents.getOrDefault(a.id))
      err("artifact " & a.id & " is not a document the reader kept")

  when defined(lcnTestHooks):
    let extractPaceMs =
      try:
        parseInt(getEnv("LCN_TEST_EXTRACT_PACE_MS", "0"))
      except ValueError:
        0
      ## [IMPL] A hosted test's pause for each MiB an extraction writes, in milliseconds (0:
      ## none): a slow disk, so that the suite can act while the worker is inside a long
      ## extraction (5-5-4; `test_pm_hosted`). Read once, when the library is loaded.

  type StoreSink = object
    ## `extractLgx`'s sink: each artifact a new file below the record's `a/` (G446).
    tree: ptr DirTree
    writer: FileWriter
    open: bool
    sync: bool
    stop: StopFlag
    failure: ExtractError
    when defined(lcnTestHooks):
      paced: int ## bytes written since the last pause

  proc sinkBegin(k: var StoreSink, path: string): bool =
    let w = k.tree[].createFile(path, k.stop)
    if w.isErr:
      k.failure = w.error
      return false
    k.writer = w.get
    k.open = true
    true

  proc sinkWrite(k: var StoreSink, data: openArray[byte]): bool =
    when defined(lcnTestHooks):
      if extractPaceMs > 0:
        k.paced += data.len
        while k.paced >= 1 shl 20:
          k.paced -= 1 shl 20
          sleep(extractPaceMs)
    let r = k.writer.append(data, k.stop)
    if r.isErr:
      k.failure = r.error
      return false
    true

  proc sinkEnd(k: var StoreSink): bool =
    k.open = false
    let r = k.writer.closeFile(k.sync)
    if r.isErr:
      k.failure = r.error
      return false
    true

  proc sinkAbort(k: var StoreSink) =
    if k.open:
      k.writer.abandon()
      k.open = false

  proc admit(
      r: InstalledRecord,
      base: string,
      m: Manifest,
      read: ArtifactReader,
      atStart: bool,
      notes: var seq[string],
  ): Result[void, StoreError] =
    ## [SPEC PM §5 l.824-830; G452] Every required result of `r` under `base`. At start, a module
    ## whose configuration artifacts no longer match their digests cannot be handed off until
    ## the package is installed again (R4), so its handoff is not required; it is noted.
    let id = Opt.some(r.identity)
    let bad = if atStart: sfDamaged else: sfAdmission
    let built = admissionHandoffs(r, base, m, r.commitment, read).valueOr:
      return err(storeError(bad, error.msg & " " & error.detail, id))
    var handoffs: seq[(string, CborValue)]
    for (module, h) in built:
      if h.isOk:
        handoffs.add((module, h.get))
      elif atStart and h.error.refusal == hrArtifactIntegrity:
        notes.add(
          "module " & module & " of " & $r.identity &
            ": its handoff is not admitted at start: " & h.error.msg
        )
      else:
        return err(storeError(bad, h.error.msg & " " & h.error.detail, id))
    admits(r, base, handoffs).isOkOr:
      let what =
        $error.result & (if error.module.len > 0: " of " & error.module
        else: "")
      return err(
        storeError(
          bad, "the " & what & " does not fit the admission bound: " & error.reason, id
        )
      )
    ok()

  # The start ----------------------------------------------------------------------------

  proc readRecordFiles*(
      root: string, e: IndexEntry
  ): Result[(Manifest, RecordFile), StoreError] =
    ## The record `e` names, read from its `m/`: its signed manifest and its record file,
    ## each checked against the other and against `e`.
    let id = Opt.some(e.identity)
    let dir = root / RecordsDir / e.rid / MetaDir
    template damaged(msg: string): untyped =
      storeError(sfDamaged, "the record of " & $e.identity & ": " & msg, id)

    let mbytes = readAll(dir / ManifestFile, MaxManifestBytes).valueOr:
      return err(damaged(error))
    let m = decodeManifest(mbytes).valueOr:
      return err(damaged("its manifest.cbor: " & error.msg))
    let commitment = m.commitment.valueOr:
      return err(damaged("its manifest.cbor: " & error.msg))
    discard readAll(dir / SignatureFile, MaxSignatureBytes).valueOr:
      return err(damaged(error))
    let fbytes = readAll(dir / recordName(e.generation), MaxRecordFileBytes).valueOr:
      return err(damaged(error))
    let f = decodeRecordFile(fbytes, m, commitment).valueOr:
      return err(damaged(recordName(e.generation) & ": " & error))
    if f.generation != e.generation:
      return err(damaged("its record file holds generation " & $f.generation))
    if f.record.identity != e.identity:
      return err(damaged("its record file is of " & $f.record.identity))
    ok((m, f))

  proc loadRecord(
      root: string, e: IndexEntry, notes: var seq[string]
  ): Result[Installed, StoreError] =
    let (m, f) = ?readRecordFiles(root, e)
    let i = Installed(rid: e.rid, file: f, manifest: m, base: baseOf(root, e.rid))
    # [PKG-0471] the bound at the current path
    ?admit(f.record, i.base, m, i.reader, atStart = true, notes)
    ok(i)

  proc deleteUnnamed(s: var InstalledStore) =
    ## [SPEC PM §15 l.1721-1728 (PKG-0611)] What no committed record names: other record
    ## directories, other generations, temporary files and the spool.
    var named = initHashSet[string]()
    for r in s.records:
      named.incl(r.rid)
    let rPath = s.root / RecordsDir
    try:
      for kind, path in walkDir(rPath, relative = true):
        if path notin named:
          removeTree(rPath / path).isOkOr:
            s.notes.add(error)
            continue
          s.notes.add("deleted " & rPath / path & ", which the index does not name")
      for r in s.records:
        let m = rPath / r.rid / MetaDir
        let keep = recordName(r.file.generation)
        for kind, path in walkDir(m, relative = true):
          if path.startsWith(RecordPrefix) and path != keep or path.isTmp:
            removeTree(m / path).isOkOr:
              s.notes.add(error)
      for kind, path in walkDir(s.root, relative = true):
        if path.isTmp:
          removeTree(s.root / path).isOkOr:
            s.notes.add(error)
    except CatchableError as e:
      s.notes.add("cannot list " & rPath & ": " & e.msg)
    removeTree(s.root / SpoolDir).isOkOr:
      s.notes.add(error)

  proc close*(f: var StoreFiles) =
    ## Releases the file half's descriptor (the worker's end).
    closeFd(f.rFd)
    f.rFd = -1

  proc close*(s: var InstalledStore) =
    ## Releases the root: its descriptor, if not handed over, and its lock.
    s.files.close()
    s.lock.release()

  proc handOver*(s: var InstalledStore): StoreFiles =
    ## [Fable's 5-5-4 check §1.2] After the start, once the snapshot is built from `records`:
    ## the file half, the descriptor with it, for the worker's `wjStart`. The store keeps the
    ## lock and no longer holds the records or their manifests.
    result = move s.files
    s.files = StoreFiles(root: result.root, rFd: -1)
    s.records.setLen(0)

  proc openStore*(stateDir: string): Result[InstalledStore, StoreError] =
    ## [G444, G445] Opens the installation root of the instance whose state directory is
    ## `stateDir`, as the Package Manager's start does before the instance is ready.
    let root = stateDir / InstallDir
    ensurePrivateDir(root).isOkOr:
      return err(storeError(sfWrite, error))
    var s = InstalledStore(stateDir: stateDir, files: StoreFiles(root: root, rFd: -1))
    s.lock = acquire(root).valueOr:
      if "in use" in error:
        return err(storeError(sfInUse, root & ": " & error))
      return err(storeError(sfWrite, error))
    template fail(e: StoreError): untyped =
      s.close()
      return err(e)

    let folds = probeIgnoresCase(root).valueOr:
      fail(storeError(sfWrite, error))
    s.files.rules = hostPathRules()
    s.files.rules.ignoreCase = s.files.rules.ignoreCase or folds
    let rPath = root / RecordsDir
    let held = readBounded(root / IndexName, MaxIndexBytes).valueOr:
      fail(storeError(sfDamaged, error))
    if held.isNone:
      # [S6] No index: a fresh root, or damage.
      var entries: seq[string]
      try:
        if dirExists(rPath):
          for kind, path in walkDir(rPath, relative = true):
            entries.add(path)
      except CatchableError as e:
        fail(storeError(sfDamaged, "cannot list " & rPath & ": " & e.msg))
      if entries.len > 0:
        fail(
          storeError(
            sfDamaged,
            root & " has no index while " & rPath & " holds " & $entries.len &
              " entries; nothing was deleted",
          )
        )
      ensurePrivateDir(rPath).isOkOr:
        fail(storeError(sfWrite, error))
      let empty = encodeIndex(InstalledIndex()).valueOr:
        fail(storeError(sfWrite, error))
      writeAtomic(root, IndexName, empty).isOkOr:
        fail(storeError(sfWrite, error))
    else:
      let index = decodeIndex(held.get).valueOr:
        fail(storeError(sfDamaged, root / IndexName & ": " & error))
      s.files.sequence = index.sequence
      for e in index.records:
        let i = loadRecord(root, e, s.notes).valueOr:
          fail(error)
        s.records.add(i)
      s.files.entries = index.records
      ensurePrivateDir(rPath).isOkOr:
        fail(storeError(sfWrite, error))
    s.files.rFd = openDir(rPath).valueOr:
      fail(storeError(sfWrite, error))
    s.files.syncMode = syncModeOf(s.files.rFd)
    s.deleteUnnamed()
    ok(s)

  # Staging ------------------------------------------------------------------------------

  proc usable(f: StoreFiles): Result[void, StoreError] =
    ## [Fable's 5-5-4 check §1.4] After a commit whose outcome is unknown the file half refuses
    ## every later stage and commit itself, so no job queued behind it writes.
    if f.broken.len > 0:
      return err(storeError(sfDamaged, "the store needs a restart: " & f.broken))
    ok()

  proc syncStaged(
      f: StoreFiles, dirFd, metaFd: cint, identity: PackageIdentity
  ): Result[void, StoreError] =
    ## [G445] Step 1's end: what the record directory holds reaches the medium, or, on Darwin,
    ## the drive, whose flush is the index's `F_FULLFSYNC`.
    case f.syncMode
    of smSyncfs:
      when defined(linux):
        syncFs(f.rFd).isOkOr:
          return err(
            storeError(
              sfWrite, "syncfs on " & f.root & ": " & error, Opt.some(identity)
            )
          )
      else:
        raiseAssert "syncfs is Linux's"
    of smEachFile:
      for (fd, what) in [(metaFd, "m/"), (dirFd, "the record directory"), (f.rFd, "r/")]:
        if fd < 0:
          continue
        fsyncOnly(fd).isOkOr:
          return err(
            storeError(
              sfWrite, "cannot sync " & what & ": " & error, Opt.some(identity)
            )
          )
    ok()

  proc crashed(f: StoreFiles, at: CrashPoint): bool =
    when defined(lcnTestHooks):
      f.crashAt == at
    else:
      false

  proc writeRecord(
      f: StoreFiles,
      p: LgxPackage,
      archive: LgxSource,
      fileBytes: seq[byte],
      dirFd: cint,
      aFd, mFd: var cint,
      stop: StopFlag,
  ): Result[void, StoreError] =
    ## The record directory's contents: `a/` with the selected variant's files, from the
    ## extraction pass over `archive`, then `m/` with the signed manifest and `m/record.1`; then
    ## the sync.
    let m = p.verified.manifest
    let sync = f.syncMode == smEachFile
    aFd = makeDirAt(dirFd, ArtifactsDir).valueOr:
      return err(error.toStore(m.identity))
    var tree = initTree(aFd)
    var sink = StoreSink(tree: addr tree, sync: sync, stop: stop)
    extractLgx(archive, p, sink, stop).isOkOr:
      case error.fault
      of xfSink:
        return err(sink.failure.toStore(m.identity))
      of xfStopped:
        return err(storeError(sfStopped, error.detail, Opt.some(m.identity)))
      of xfDiffers:
        return err(storeError(sfSource, error.detail, Opt.some(m.identity)))
    tree.finish(sync).isOkOr:
      return err(error.toStore(m.identity))
    mFd = makeDirAt(dirFd, MetaDir).valueOr:
      return err(error.toStore(m.identity))
    var meta = initTree(mFd)
    meta.extractFile(ManifestFile, m.encoded, sync, stop).isOkOr:
      return err(error.toStore(m.identity))
    meta.extractFile(SignatureFile, p.signature, sync, stop).isOkOr:
      return err(error.toStore(m.identity))
    meta.extractFile(recordName(1), fileBytes, sync, stop).isOkOr:
      return err(error.toStore(m.identity))
    if f.crashed(cpAfterFiles):
      return
        err(storeError(sfStopped, "crash hook: after the files", Opt.some(m.identity)))
    f.syncStaged(dirFd, mFd, m.identity)

  proc newRecordId*(): Result[string, string] =
    ## [G444] A new record directory's name: 128 bits from the OS random source.
    newRid()

  proc stageFiles*(
      f: var StoreFiles,
      p: LgxPackage,
      archive: LgxSource,
      record: InstalledRecord,
      rid: string,
      archiveDigest: Blake3Digest,
      stop: StopFlag = nil,
  ): Result[StagedFiles, StoreError] =
    ## [SPEC PM §7.1 l.926-933, l.963] `record`, the record of the opened archive `p`
    ## (selected for installation, verified under the current trust), written in full in the
    ## new directory `rid` and synced. Its files come from the extraction pass over `archive`,
    ## the source `p` was judged from (G446). Nothing names it until a commit.
    ?f.usable()
    let m = p.verified.manifest
    let id = Opt.some(m.identity)
    # [SPEC PM l.924] the root's own rules, which may be stricter than the host's
    var paths: seq[string]
    var dirs = initHashSet[string]()
    for a in p.artifacts:
      paths.add(a.artifact.path)
      let segs = a.artifact.path.split('/')
      for i in 1 ..< segs.len:
        dirs.incl(segs[0 ..< i].join("/"))
    for d in dirs:
      paths.add(d)
    paths.sort()
    checkInstallPaths(paths, f.rules).isOkOr:
      return err(storeError(sfPaths, "variant " & p.variant.id & ": " & error, id))
    let base = baseOf(f.root, rid)
    # [G452] Before any write.
    var notes: seq[string]
    ?admit(record, base, m, packageReader(unsafeAddr p), atStart = false, notes)
    let file = RecordFile(record: record, generation: 1, archiveDigest: archiveDigest)
    let fileBytes = encodeRecordFile(file).valueOr:
      return err(storeError(sfAdmission, error, id))
    let dir = f.recordDir(rid)
    let dirFd = makeDirAt(f.rFd, rid).valueOr:
      return err(error.toStore(m.identity))
    var aFd, mFd = -1.cint
    let r = f.writeRecord(p, archive, fileBytes, dirFd, aFd, mFd, stop)
    closeFd(aFd)
    closeFd(mFd)
    closeFd(dirFd)
    if r.isErr:
      if not f.crashed(cpAfterFiles):
        # Nothing names it: deleted now, or at the next start.
        discard removeTree(dir)
      return err(r.error)
    ok(StagedFiles(rid: rid, file: file, base: base, newDir: true))

  proc stage*(
      s: var InstalledStore,
      p: LgxPackage,
      archive: LgxSource,
      source: PackageSource,
      edges: seq[ResolvedDependency],
      archiveDigest: Blake3Digest,
      stop: StopFlag = nil,
  ): Result[Staged, StoreError] =
    ## `stageFiles` with the record built from `p` and a new rid.
    let rid = newRid().valueOr:
      return err(storeError(sfWrite, error, Opt.some(p.verified.manifest.identity)))
    let st = ?s.files.stageFiles(
      p, archive, installedRecord(p, source, edges), rid, archiveDigest, stop
    )
    ok(
      Staged(
        rid: st.rid,
        file: st.file,
        manifest: p.verified.manifest,
        base: st.base,
        newDir: true,
      )
    )

  proc stageSignerFiles*(
      f: var StoreFiles,
      rid: string,
      generation: uint64,
      identity: PackageIdentity,
      signer: PackageSigner,
      stop: StopFlag = nil,
  ): Result[StagedFiles, StoreError] =
    ## [SPEC PM §5; G445] The committed record `rid` at `generation` with `signer` retained
    ## instead, as its next generation `m/record.<g+1>`, synced. The record and its manifest
    ## are read from its directory (Fable's 5-5-4 check §1.3); the artifacts are not touched.
    ?f.usable()
    let id = Opt.some(identity)
    let (m, cur) = ?readRecordFiles(
      f.root, IndexEntry(rid: rid, generation: generation, identity: identity)
    )
    var file = cur
    file.record.signer = signer
    file.generation = cur.generation + 1
    let base = baseOf(f.root, rid)
    let held = Installed(rid: rid, file: cur, manifest: m, base: base)
    var notes: seq[string]
    ?admit(file.record, base, m, held.reader, atStart = false, notes)
    let bytes = encodeRecordFile(file).valueOr:
      return err(storeError(sfAdmission, error, id))
    let dir = f.recordDir(rid)
    let dirFd = openDir(dir).valueOr:
      return err(storeError(sfWrite, error, id))
    defer:
      closeFd(dirFd)
    let mFd = openDir(dir / MetaDir).valueOr:
      return err(storeError(sfWrite, error, id))
    defer:
      closeFd(mFd)
    var meta = initTree(mFd)
    let name = recordName(file.generation)
    let made = meta.extractFile(name, bytes, f.syncMode == smEachFile, stop)
    if made.isErr:
      if made.error.fault != efExists:
        discard removeTree(dir / MetaDir / name)
      return err(made.error.toStore(identity))
    f.syncStaged(-1, mFd, identity).isOkOr:
      discard removeTree(dir / MetaDir / name)
      return err(error)
    ok(StagedFiles(rid: rid, file: file, base: base))

  proc stageSigner*(
      s: var InstalledStore, at: int, signer: PackageSigner, stop: StopFlag = nil
  ): Result[Staged, StoreError] =
    ## `stageSignerFiles` for the committed record `records[at]`.
    let cur = s.records[at]
    let st = ?s.files.stageSignerFiles(
      cur.rid, cur.file.generation, cur.file.record.identity, signer, stop
    )
    ok(Staged(rid: st.rid, file: st.file, manifest: cur.manifest, base: cur.base))

  proc abandonFiles*(
      f: StoreFiles, rid: string, generation: uint64, newDir: bool
  ): Result[void, string] =
    ## Deletes what a staging wrote; nothing names it.
    if newDir:
      removeTree(f.recordDir(rid))
    else:
      removeTree(f.recordDir(rid) / MetaDir / recordName(generation))

  proc abandon*(s: var InstalledStore, st: Staged): Result[void, string] =
    s.files.abandonFiles(st.rid, st.file.generation, st.newDir)

  # The commit ---------------------------------------------------------------------------

  proc commitFiles*(
      f: var StoreFiles, add: openArray[IndexEntry], drop: openArray[string]
  ): Result[Committed, StoreError] =
    ## [SPEC PM §15 l.1721-1728 (PKG-0610); G445] One replacement of the index: the records
    ## of `drop` (rids) go, each of `add` is named (a new record, or, when its rid is named
    ## already, that record's next generation). Answers the new sequence and what the new
    ## index no longer names, to be retired.
    ?f.usable()
    var gone = initHashSet[string]()
    for rid in drop:
      gone.incl(rid)
    var next: seq[IndexEntry]
    var retired: seq[RetiredItem]
    var named = initHashSet[string]()
    for e in f.entries:
      named.incl(e.rid)
      if e.rid in gone:
        retired.add(RetiredItem(rid: e.rid))
        continue
      var kept = e
      for a in add:
        if a.rid == e.rid:
          if a.identity != e.identity:
            # [Fable's 5-5-4 check §1.4] the identity check stays with the commit
            return err(
              storeError(
                sfConflict,
                e.rid & " holds " & $e.identity & ", not " & $a.identity,
                Opt.some(a.identity),
              )
            )
          retired.add(RetiredItem(rid: e.rid, generation: e.generation))
          kept.generation = a.generation
      next.add(kept)
    for a in add:
      if a.rid in named:
        continue
      for e in next:
        if e.identity == a.identity:
          # [PKG-0182] one record, and so one commitment, per identity
          return err(
            storeError(
              sfConflict,
              $a.identity & " is installed as " & e.rid,
              Opt.some(a.identity),
            )
          )
      next.add(a)
    next.sort(
      proc(a, b: IndexEntry): int =
        identityOrder(a.identity, b.identity)
    )
    let index = InstalledIndex(sequence: f.sequence + 1, records: next)
    let bytes = encodeIndex(index).valueOr:
      return err(storeError(sfIndexBound, error))
    when defined(lcnTestHooks):
      if f.crashAt == cpAfterIndexTmp:
        let tmp = f.root / IndexName & TmpSuffix
        var text = newString(bytes.len)
        for i, b in bytes:
          text[i] = char(b)
        try:
          writeFile(tmp, text)
        except CatchableError as e:
          return err(storeError(sfWrite, e.msg))
        return err(storeError(sfStopped, "crash hook: after index.tmp"))
    writeAtomic(f.root, IndexName, bytes).isOkOr:
      # The rename may have happened: only a restart knows which index is in place.
      f.broken = error
      return err(storeError(sfWrite, error))
    when defined(lcnTestHooks):
      if f.crashAt == cpAfterRename:
        return err(storeError(sfStopped, "crash hook: after the rename"))
    f.sequence = index.sequence
    f.entries = index.records
    ok(Committed(sequence: f.sequence, retired: retired))

  proc commit*(
      s: var InstalledStore, add: openArray[Staged], drop: openArray[string]
  ): Result[uint64, StoreError] =
    ## `commitFiles`, with the store's records and retired list following it.
    var entries: seq[IndexEntry]
    for st in add:
      entries.add(
        IndexEntry(
          rid: st.rid, generation: st.file.generation, identity: st.file.record.identity
        )
      )
    let c = ?s.files.commitFiles(entries, drop)
    var gone = initHashSet[string]()
    for rid in drop:
      gone.incl(rid)
    var next: seq[Installed]
    for r in s.records:
      if r.rid in gone:
        continue
      var kept = r
      for st in add:
        if not st.newDir and st.rid == r.rid:
          kept.file = st.file
      next.add(kept)
    for st in add:
      if st.newDir:
        next.add(
          Installed(rid: st.rid, file: st.file, manifest: st.manifest, base: st.base)
        )
    next.sort(
      proc(a, b: Installed): int =
        identityOrder(a.file.record.identity, b.file.record.identity)
    )
    s.records = next
    for item in c.retired:
      s.retired.add(Retired(sequence: c.sequence, item: item))
    ok(c.sequence)

  # Retirement and the retained hash -----------------------------------------------------

  func retiredCount*(s: InstalledStore): int =
    s.retired.len

  proc collectFiles*(f: StoreFiles, items: openArray[RetiredItem]): Collected =
    ## [R1] Deletes each retired item. One the index names (a whole record directory, or its
    ## current generation) is refused and reported: the one mistake that would lose a
    ## committed package (Fable's 5-5-4 check §1.4).
    for it in items:
      var named = false
      for e in f.entries:
        if e.rid == it.rid and (it.generation == 0 or it.generation == e.generation):
          named = true
          break
      if named:
        result.refused.add(it)
        continue
      let path =
        if it.generation == 0:
          f.recordDir(it.rid)
        else:
          f.recordDir(it.rid) / MetaDir / recordName(it.generation)
      let done = removeTree(path)
      if done.isOk:
        inc result.deleted
      else:
        result.failures.add(done.error)
        result.failed.add(it)

  proc collect*(s: var InstalledStore, oldestHeld: Opt[uint64]): Collected =
    ## [R1] Deletes what was retired at or before `oldestHeld`. A snapshot at that sequence
    ## no longer names it.
    result = s.files.collectFiles(due(s.retired, oldestHeld))
    var keep: seq[Retired]
    for r in s.retired:
      if (oldestHeld.isSome and oldestHeld.get < r.sequence) or r.item in result.failed:
        keep.add(r)
    s.retired = keep

  proc checkRetainedFiles*(
      base: string,
      identity: PackageIdentity,
      artifacts: openArray[InstalledArtifact],
      stop: StopFlag = nil,
  ): Result[void, StoreError] =
    ## [SPEC PM §5 l.818, §10 l.1176 (PKG-0181, PKG-0293); G445, G448] Each artifact still
    ## holds its signed bytes: hashed below `base` (a record's `a/`), no link followed. The
    ## worker's half of the retained check (5-5-4): plain data, no `Installed`.
    let root = openDir(base).valueOr:
      return err(storeError(sfIntegrity, error, Opt.some(identity)))
    defer:
      closeFd(root)
    for a in artifacts:
      let h = hashBelow(root, a.path, stop).valueOr:
        return err(error.toStore(identity))
      if h != a.hash:
        return err(
          storeError(
            sfIntegrity,
            localPath(base, a) & " does not match its signed digest",
            Opt.some(identity),
          )
        )
    ok()

  proc checkRetained*(i: Installed, stop: StopFlag = nil): Result[void, StoreError] =
    ## [SPEC PM §5 l.818, §10 l.1176 (PKG-0181, PKG-0293); G445] Each artifact of `i` still
    ## holds its signed bytes: hashed below `a/`, no link followed.
    checkRetainedFiles(i.base, i.file.record.identity, i.file.record.artifacts, stop)

{.pop.}
