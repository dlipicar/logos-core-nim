## The Package Manager's operations through the engine (Tier 5 step 5-5-4; DECISIONS G448,
## G449; docs/PACKAGE-MANAGER.md §11): the slots and their queues, cancel, the operation
## deadline, the snapshot holds, and the checks that run before any resolution. The engine
## does no I/O: `pmworld` answers its calls and runs the worker's jobs inline.

import std/[os, sequtils, strutils, tables]
import unittest2
import logos_sdk/cbor
import ../src/logos_core/package/[errors, lgx, manifest, records, resolver]
import ../src/logos_core/pm/input_types as pm_input_types
import ./support/[lgxbuild, pmworld]

when defined(posix):
  import std/posix
  import ../src/logos_core/pm/store
  from ../src/logos_core/pm/admission import admissionLimitForTests

let (orgKey, orgPub) = testKey(1)

# Built once: each signature takes about a second.
let app100 = packed(dataManifest("app", "1.0.0", [("lib", "1.0.0")]), "org", orgKey)
let lib100 = packed(dataManifest("lib", "1.0.0"), "org", orgKey)

let (rogueKey, _) = testKey(2)
let top100 = packed(dataManifest("top", "1.0.0", [("mid", "1.0.0")]), "org", orgKey)
let mid100 = packed(dataManifest("mid", "1.0.0", [("base", "1.0.0")]), "org", orgKey)
let mid110 = packed(dataManifest("mid", "1.1.0", [("base", "1.0.0")]), "org", rogueKey)
let base100 = packed(dataManifest("base", "1.0.0"), "org", orgKey)

let example = modulePackage() # logos.example 1.0.0, one module with its artifact
let exampleBytes = example.packed("org", orgKey)

let (otherKey, otherPub) = testKey(3) # a second accepted signer, for lib only
let libOther = packed(dataManifest("lib", "1.0.0"), "org2", otherKey)
  # the same manifest, so the same commitment, under another accepted signer

let orgTrust = trustOf(
  [
    anchorOf("org", ["app", "base", "lib", "logos.example", "mid", "top"], orgPub),
    anchorOf("org2", ["lib"], otherPub),
  ]
).trustBytes
let orgTrustInput = trustInputOf([("org", orgPub, @["app", "lib", "logos.example"])])

let work = currentSourcePath().parentDir.parentDir / "build" / "pm_install"
removeDir(work)
createDir(work)

type Scene = object
  w: World
  objects: Table[seq[byte], seq[byte]]
  calls: seq[Command]

proc scene(
    entries: openArray[(CatalogEntry, seq[byte])],
    limits = Opt.none(pm_input_types.LcnPmLimits),
    spoolBudgetArchives = SpoolBudgetArchives,
    trust = orgTrust,
): Scene =
  ## The engine with `entries` as its kept, matching catalog, each archive served under
  ## its entry's locator, and its catalog binding up.
  var cat: seq[CatalogEntry]
  for (e, archive) in entries:
    cat.add(e)
    if archive.len > 0:
      result.objects[e.source.objectLocator] = archive
  let doc = catalogBytes(cat)
  result.objects[bytesOf("catalog")] = doc
  result.w = newWorld(
    doc,
    kept = keptFor(doc),
    limits = limits,
    trust = trust,
    spoolBudgetArchives = spoolBudgetArchives,
  )
  result.w.emit(result.w.e.start())
  result.w.bringUp()
  result.w.serve(result.objects, result.calls)
  result.calls.setLen(0)

proc ident(name, version: string): PackageIdentity =
  PackageIdentity(package: name, version: version)

proc pkgRoot(name: string): RootReference =
  RootReference(package: Opt.some(name))

proc install(name: string): OperationRequest =
  OperationRequest(kind: opInstall, root: pkgRoot(name))

proc inspect(name: string): OperationRequest =
  OperationRequest(kind: opInspect, root: pkgRoot(name))

proc remove(name, version: string): OperationRequest =
  OperationRequest(kind: opRemove, identity: ident(name, version))

proc installVersion(name, version: string): OperationRequest =
  OperationRequest(
    kind: opInstall,
    root: RootReference(package: Opt.some(name), version: Opt.some(version)),
  )

proc update(name, version: string): OperationRequest =
  OperationRequest(
    kind: opUpdate,
    root:
      RootReference(package: Opt.some(name), newerThan: Opt.some(ident(name, version))),
  )

proc submit(s: var Scene, request: uint64, op: OperationRequest) =
  s.w.emit(s.w.e.submit(request, op))

proc answerOf(s: Scene, request: uint64): Opt[OperationAnswer] =
  for c in s.w.answers:
    if c.answerTo == request:
      return Opt.some(c.answer)

proc responseOf(s: Scene, request: uint64): CborValue =
  let a = s.answerOf(request)
  doAssert a.isSome, "no answer to " & $request
  doAssert a.get.kind == oaResponse, a.get.reason
  a.get.response

proc resultOf(s: Scene, request: uint64): CborValue =
  ## The answer's §15 response value, encoded by the worker or not.
  let a = s.answerOf(request)
  doAssert a.isSome, "no answer to " & $request
  case a.get.kind
  of oaResponse:
    a.get.response
  of oaEncoded:
    decodeCbor(a.get.encoded).get
  of oaModuleError:
    raiseAssert "MODULE_ERROR: " & a.get.reason

proc encodedOf(s: Scene, request: uint64): CborValue =
  let a = s.answerOf(request)
  doAssert a.isSome, "no answer to " & $request
  doAssert a.get.kind == oaEncoded, $a.get.kind
  decodeCbor(a.get.encoded).get

proc field(v: CborValue, name: string): CborValue =
  if v.kind != ckMap:
    return CborValue()
  for (k, x) in v.entries:
    if k == cbor(name):
      return x
  CborValue()

proc installedIdentity(v: CborValue): PackageIdentity =
  ## `{installed: record}`'s identity.
  let id = v.field("installed").field("identity")
  PackageIdentity(package: id.field("package").text, version: id.field("version").text)

proc errorMessage(v: CborValue): string =
  ## The response's `package_error` message; empty for a success or none.
  for (k, x) in v.entries:
    if k == cbor("error"):
      for (k2, y) in x.entries:
        if k2 == cbor("message"):
          return y.text

proc errorCode(v: CborValue): string =
  ## The response's `package_error` code; empty for a success.
  for (k, x) in v.entries:
    if k == cbor("error"):
      for (k2, y) in x.entries:
        if k2 == cbor("code"):
          return y.text

proc statsFor(s: Scene, locator: string): int =
  s.w.queue.countIt(it.kind == cmStat and it.locator == bytesOf(locator))

func commitOf(seed: char): ManifestCommitment =
  var c: ManifestCommitment
  for i in 0 ..< c.schemaRoot.len:
    c.schemaRoot[i] = byte(seed)
  c

proc installedOf(
    name, version: string, seed: char, edges: openArray[(string, string, char)] = []
): InstalledPackage =
  ## A record as resolution reads it; no file backs it, so no test here resolves over it.
  result = InstalledPackage(identity: ident(name, version), commitment: commitOf(seed))
  for (n, v, c) in edges:
    result.resolvedDependencies.add(
      ResolvedDependency(identity: ident(n, v), commitment: commitOf(c))
    )

proc snapshotOf(sequence: uint64, records: openArray[InstalledPackage]): Snapshot =
  result = Snapshot(sequence: sequence)
  for p in records:
    result.records.add(SnapRecord(package: p, rid: "rid-" & $p.identity))

suite "the operations' slots (G449; plan §4.6, §4.13)":
  test "[IMPL-DECISION G449] an inspection does not wait for a mutation, nor a mutation for an inspection":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.submit(1, install("app"))
    check s.w.e.slotRunning(slMutation) == Opt.some(1'u64)
    s.submit(2, inspect("app"))
    check s.w.e.slotRunning(slInspection) == Opt.some(2'u64)
    check s.w.e.slotWaiting(slMutation) == 0
    check s.w.e.slotWaiting(slInspection) == 0
    check s.w.e.heldSnapshots == 2

  test "[PKG-0409] [IMPL-DECISION G449] two mutations queue; a cancelled waiting request never runs, and the one behind moves up":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.submit(1, install("app"))
    s.submit(2, install("app"))
    s.submit(3, install("app"))
    check s.w.e.slotWaiting(slMutation) == 2
    s.w.emit(s.w.e.cancel(2))
    check s.w.e.slotWaiting(slMutation) == 1
    check s.answerOf(2).isNone
    # The running one, cancelled, frees the slot (R2): the third runs next.
    s.w.emit(s.w.e.cancel(1))
    check s.w.e.slotRunning(slMutation) == Opt.some(3'u64)
    check s.w.e.slotWaiting(slMutation) == 0
    check s.w.logs.anyIt(
      it.startsWith("install_package ended after") and it.endsWith(": cancelled")
    )
    check s.w.e.heldSnapshots == 1

  test "[IMPL-DECISION G449] with 16 waiting, the next request to that slot is MODULE_ERROR at once, takes no snapshot and starts no work, and the other slot still admits":
    for slot in [slMutation, slInspection]:
      var s =
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
      let op =
        if slot == slMutation:
          install("app")
        else:
          inspect("app")
      for i in 1'u64 .. uint64(MaxQueuedOperations + 1):
        s.submit(i, op)
      check s.w.e.slotWaiting(slot) == MaxQueuedOperations
      check s.w.answers.len == 0
      let queued = s.w.queue.len
      let held = s.w.e.heldSnapshots
      s.submit(100, op)
      let a = s.answerOf(100)
      check a.isSome and a.get.kind == oaModuleError
      check a.get.reason ==
        "the Package Manager's " & (
          if slot == slMutation: "mutation" else: "inspection"
        ) & " queue is full"
      check s.w.queue.len == queued
      check s.w.e.heldSnapshots == held
      check s.w.e.slotWaiting(slot) == MaxQueuedOperations
      let other =
        if slot == slMutation:
          inspect("app")
        else:
          install("app")
      s.submit(200, other)
      check s.w.e.slotRunning(if slot == slMutation: slInspection else: slMutation) ==
        Opt.some(200'u64)

  test "[IMPL-DECISION G449] two inspections queue: the second runs once the first ends":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.submit(1, inspect("app"))
    s.submit(2, inspect("lib"))
    check s.w.e.slotRunning(slInspection) == Opt.some(1'u64)
    check s.w.e.slotWaiting(slInspection) == 1
    check s.w.e.heldSnapshots == 1
    s.w.serve(s.objects, s.calls)
    check s.encodedOf(1).field("inspection").field("manifest").field("package").text ==
      "app"
    check s.encodedOf(2).field("inspection").field("manifest").field("package").text ==
      "lib"
    check s.w.e.slotRunning(slInspection).isNone
    check s.w.e.heldSnapshots == 0

  test "[IMPL-DECISION G449] a request id in use is invalid-request, and the operation that holds it goes on":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.submit(1, install("app"))
    s.submit(1, inspect("app"))
    check s.responseOf(1) == errorResult(pecInvalidRequest, "the request id is in use")
    check s.w.e.slotRunning(slMutation) == Opt.some(1'u64)
    check s.w.e.slotRunning(slInspection).isNone

  test "[IMPL-DECISION G449] a stop answers every operation, running and waiting, package-unavailable":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.submit(1, install("app"))
    s.submit(2, install("app"))
    s.submit(3, inspect("app"))
    s.w.emit(s.w.e.stop())
    for r in [1'u64, 2, 3]:
      check s.responseOf(r) ==
        errorResult(pecPackageUnavailable, "the Package Manager is stopping")
    check s.w.e.heldSnapshots == 0
    check s.w.e.slotRunning(slMutation).isNone

suite "the operation deadline (G449; plan §4.13, Fable's §4)":
  test "[IMPL-DECISION G449] a stalled fetch past operation_deadline_ms ends the operation package-unavailable, cancels its call, logs its time and bytes, and passes the slot on":
    var s = scene(
      [(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)],
      limits = Opt.some(LcnPmLimits(operation_deadline_ms: Opt.some(1_000'u32))),
    )
    s.w.clock.ms = 10_000
    s.submit(1, install("app"))
    s.submit(2, inspect("app"))
    s.submit(3, install("app"))
    check s.statsFor("app@1.0.0") == 1 # one retrieval at a time on the binding
    let stat = s.w.queue.filterIt(it.kind == cmStat)[0]
    # The waiting request's clock has not started: only the two running hold timers.
    check s.w.queue.countIt(it.kind == cmTimer and it.ms == 1_000) == 2
    let deadline = s.w.timerFor(1_000) # the inspection's, the newest
    discard deadline
    let first = s.w.timerFor(1_000) # the install's
    s.w.clock.ms = 11_250
    s.w.handle(fired(first))
    check s.responseOf(1) ==
      errorResult(pecPackageUnavailable, "the operation's time bound was reached")
    check s.w.queue.anyIt(it.kind == cmCancelCall and it.cancelled == stat.call)
    check "a root operation stopped at the operation deadline operation_deadline_ms (1000)" in
      s.w.logs
    check "install_package ended after 1250 ms, 0 archive bytes retrieved: package-unavailable" in
      s.w.logs
    # The slot passes on; the inspection is untouched.
    check s.w.e.slotRunning(slMutation) == Opt.some(3'u64)
    check s.w.e.slotRunning(slInspection) == Opt.some(2'u64)
    check s.answerOf(2).isNone

  test "[IMPL-DECISION G449] a deadline that fires after its operation ended does nothing":
    var s = scene(
      [(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)],
      limits = Opt.some(LcnPmLimits(operation_deadline_ms: Opt.some(1_000'u32))),
    )
    s.submit(1, install("app"))
    let t = s.w.timerFor(1_000)
    s.w.emit(s.w.e.cancel(1))
    s.w.handle(fired(t))
    check s.w.answers.len == 0
    check s.w.e.slotRunning(slMutation).isNone

suite "the checks before resolution (G449; PM §15)":
  test "[PKG-0399] [PKG-0402] remove: an absent identity succeeds with {}, and one another record depends on, through a two-level closure, is package-in-use":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.w.e.setSnapshot(
      snapshotOf(
        3,
        [
          installedOf("app", "1.0.0", 'a', [("mid", "1.0.0", 'm')]),
          installedOf("mid", "1.0.0", 'm', [("base", "1.0.0", 'b')]),
          installedOf("base", "1.0.0", 'b'),
        ],
      )
    )
    s.submit(1, remove("absent", "1.0.0"))
    check s.responseOf(1) == removedResult()
    s.submit(2, remove("base", "1.0.0"))
    check s.responseOf(2) ==
      errorResult(pecPackageInUse, "another installed package depends on it")
    s.submit(3, remove("mid", "1.0.0"))
    check s.responseOf(3) ==
      errorResult(pecPackageInUse, "another installed package depends on it")
    check s.w.e.heldSnapshots == 0
    check "remove_package ended after 0 ms, 0 archive bytes retrieved: not installed" in
      s.w.logs

  test "[PKG-0399] an edge to the same identity with another commitment does not hold a record in use":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.w.e.setSnapshot(
      snapshotOf(
        1,
        [
          installedOf("app", "1.0.0", 'a', [("base", "1.0.0", 'x')]),
          installedOf("base", "1.0.0", 'b'),
        ],
      )
    )
    s.submit(1, update("base", "1.0.0"))
    let a = s.answerOf(1)
    check a.isNone or a.get.kind != oaResponse or
      a.get.response !=
      errorResult(pecPackageInUse, "another installed package depends on it")

  test "[PKG-0406] update: a current that another record depends on is package-in-use, before any retrieval":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.w.e.setSnapshot(
      snapshotOf(
        1,
        [
          installedOf("app", "1.0.0", 'a', [("lib", "1.0.0", 'l')]),
          installedOf("lib", "1.0.0", 'l'),
        ],
      )
    )
    s.submit(1, update("lib", "1.0.0"))
    check s.responseOf(1) ==
      errorResult(pecPackageInUse, "another installed package depends on it")
    check not s.w.has({cmStat})

  test "[PKG-0410] [IMPL-DECISION G449] an operation holds the snapshot current when it takes its slot, and a later one the newer":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.submit(1, install("app"))
    s.w.e.setSnapshot(snapshotOf(1, []))
    s.submit(2, inspect("app"))
    check s.w.e.heldSnapshots == 2
    s.w.emit(s.w.e.cancel(1))
    check s.w.e.heldSnapshots == 1
    s.w.emit(s.w.e.cancel(2))
    check s.w.e.heldSnapshots == 0
    check wjCollect notin s.w.jobs # nothing was retired

proc answerOne(s: var Scene) =
  ## Answers the oldest call, from the scene's objects, and runs every continue due.
  let c = s.w.take({cmStat, cmRead})
  s.calls.add(c)
  let data = s.objects.getOrDefault(c.locator, @[])
  s.w.handle(
    answered(
      c.call,
      if c.kind == cmStat:
        sized(uint64(data.len))
      else:
        dataOf(data[int(c.offset) ..< int(c.offset) + int(c.length)]),
    )
  )
  while s.w.turn():
    discard

proc untilStat(s: var Scene, locator: string) =
  ## Answers calls until the stat of `locator` is the next call.
  while true:
    let next = s.w.queue.filterIt(it.kind in {cmStat, cmRead})
    doAssert next.len > 0, "no call before " & locator
    if next[0].kind == cmStat and next[0].locator == bytesOf(locator):
      return
    s.answerOne()

suite "a mutation's spool budget (G446; plan §4.3)":
  test "[IMPL-DECISION G446] a mutation keeps its judged archives within its budget: the root's is never deleted, the ineligible go first, then the oldest, and every one goes when it ends":
    let biggest = [top100, mid100, mid110, base100].mapIt(it.len).max
    var s = scene(
      [
        (entryOf("top", "1.0.0"), top100),
        (entryOf("mid", "1.1.0"), mid110),
        (entryOf("mid", "1.0.0"), mid100),
        (entryOf("base", "1.0.0"), base100),
      ],
      limits = Opt.some(LcnPmLimits(archive_bytes: Opt.some(uint64(biggest)))),
      spoolBudgetArchives = 1,
    )
    s.submit(1, install("top"))
    s.untilStat("mid@1.0.0")
    # The root's and the ineligible mid 1.1.0 (another signer) are kept, over the budget:
    # nothing could be deleted for the second, since the root's never is.
    check s.w.e.keptArchives(1) == 2
    check s.w.e.spoolEvictions == 0
    s.untilStat("base@1.0.0")
    # mid 1.0.0 made room by deleting the ineligible one, not the root's.
    check s.w.e.spoolEvictions == 1
    check s.w.e.keptArchives(1) == 2
    s.w.serve(s.objects, s.calls)
    # base made room by deleting mid 1.0.0, the oldest eligible one that is not the root's.
    check s.w.e.spoolEvictions == 2
    check s.answerOf(1).isSome
    check s.w.e.keptArchives(1) == 0
    check s.w.e.spooled == 0
    check s.w.e.mutationSpoolUsed == 0
    check s.w.e.shareUsed == 0

  test "[IMPL-DECISION G446] an inspection's archives use the inspections' share and are deleted once judged":
    var s =
      scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)])
    s.submit(1, inspect("app"))
    s.untilStat("lib@1.0.0")
    check s.w.e.keptArchives(1) == 0
    check s.w.e.mutationSpoolUsed == 0

suite "the retained check (G448)":
  test "[IMPL-DECISION G448] an installed record's retained bytes are hashed on the worker: intact, the resolution goes on; altered, artifact-integrity-failed":
    when defined(posix):
      let dir = work / "retained"
      removeDir(dir)
      createDir(dir)
      var store = openStore(dir).get
      let opened = openLgx(
        exampleBytes, orgTrustInput, linuxHost, DefaultLgxLimits, PathRules()
      ).get
      let st = store.stage(
        opened,
        bytesSource(exampleBytes),
        lgxSource("main", "logos.example@1.0.0"),
        @[],
        blake3(exampleBytes),
      ).get
      discard store.commit([st], []).get
      let base = store.records[0].base
      var s = scene([(entryOf("logos.example", "1.0.0"), exampleBytes)])
      s.w.attachStore(store)
      check s.w.e.snapshot.sequence == 1
      s.submit(1, install("logos.example"))
      s.w.serve(s.objects, s.calls)
      check wjRetained in s.w.jobs
      # Installed already: the current record, read from its directory by the worker.
      let first = s.answerOf(1)
      check first.isSome and first.get.kind == oaEncoded
      check s.encodedOf(1).errorCode == ""
      check s.encodedOf(1).installedIdentity == ident("logos.example", "1.0.0")
      # Bytes changed outside the Package Manager are caught at the next use (PKG-0181).
      let file = base / "lib" / "libalpha.so"
      doAssert chmod(cstring(file), 0o600) == 0
      var text = readFile(file)
      text[0] = char(ord(text[0]) xor 1)
      writeFile(file, text)
      s.submit(2, install("logos.example"))
      s.w.serve(s.objects, s.calls)
      check s.resultOf(2).errorCode == "artifact-integrity-failed"
      store.close()
    else:
      skip()

# Installing, removing and updating (5-5-4) ---------------------------------------------

when defined(posix):
  let lib110 = packed(dataManifest("lib", "1.1.0"), "org", orgKey)

  template withStore(name: string, made: Scene, body: untyped) =
    ## The scene `made` over a fresh installed state `<work>/<name>`, its file half on the
    ## inline worker as the shell's open puts it.
    let dir {.inject.} = work / name
    removeDir(dir)
    createDir(dir)
    var store {.inject.} = openStore(dir).get
    var s {.inject.} = made
    s.w.attachStore(store)
    body

  proc diskSnapshot(s: var Scene, store: var InstalledStore, dir: string): Snapshot =
    ## [Fable's check §2] The snapshot a restart builds from the disk: the worker's half
    ## and the lock released first.
    s.w.worker.close()
    store.close()
    var again = openStore(dir).get
    result = snapshotOf(again)
    again.close()

  proc sameRecords(a, b: Snapshot): bool =
    ## Every record equal, its module declarations by their encodings.
    if a.sequence != b.sequence or a.records.len != b.records.len:
      return false
    for i in 0 ..< a.records.len:
      let (x, y) = (a.records[i], b.records[i])
      if x.rid != y.rid or x.generation != y.generation or x.base != y.base or
          x.artifacts != y.artifacts:
        return false
      let (p, q) = (x.package, y.package)
      if p.identity != q.identity or p.commitment != q.commitment or p.signer != q.signer or
          p.source != q.source or p.resolvedDependencies != q.resolvedDependencies:
        return false
      if p.modules.mapIt(encodeCbor(it.value)) != q.modules.mapIt(encodeCbor(it.value)):
        return false
      if p.dependencies.len != q.dependencies.len:
        return false
      for k in 0 ..< p.dependencies.len:
        let (d, e) = (p.dependencies[k], q.dependencies[k])
        if d.package != e.package or d.kind != e.kind or d.version != e.version or
            d.contracts.mapIt(encodeCbor(it)) != e.contracts.mapIt(encodeCbor(it)):
          return false
    true

  func identities(s: Snapshot): seq[PackageIdentity] =
    s.records.mapIt(it.package.identity)

  func recordOf(s: Snapshot, identity: PackageIdentity): SnapRecord =
    for r in s.records:
      if r.package.identity == identity:
        return r

  suite "install, remove, update and inspect (G449; PM §15)":
    test "[PKG-0189] [BCP-0033] [BCP-0035] [PKG-0395] [PKG-0396] [PKG-0397] [PKG-0436] install: the dependency first, each committed on its own, the root last; the same commitment again gives the same record; the live snapshot equals a restart's":
      withStore(
        "install",
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)]),
      ):
        s.submit(1, install("app"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("app", "1.0.0")
        check s.w.e.snapshot.sequence == 2
        check s.w.e.snapshot.identities ==
          @[ident("app", "1.0.0"), ident("lib", "1.0.0")]
        check s.w.jobs.filterIt(it in {wjStage, wjCommit}) ==
          @[wjStage, wjCommit, wjStage, wjCommit]
        check s.w.e.installedChanges == 2
        check s.w.e.spooled == 0
        # [PKG-0436] The signer the verification established, kept with each record.
        check s.w.e.snapshot.records.allIt(it.package.signer.key == orgPub)
        s.submit(2, install("app"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(2).installedIdentity == ident("app", "1.0.0")
        check s.w.e.snapshot.sequence == 2
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0399] [PKG-0400] [PKG-0401] remove: a dependency in use is package-in-use; the root goes, its dependency stays, and its directory is deleted once no snapshot names it":
      withStore(
        "remove",
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)]),
      ):
        s.submit(1, install("app"))
        s.w.serve(s.objects, s.calls)
        let appDir = s.w.e.snapshot.records[0].base.parentDir
        s.submit(2, remove("lib", "1.0.0"))
        check s.resultOf(2).errorCode == "package-in-use"
        s.submit(3, remove("app", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(3) == removedResult()
        check s.w.e.snapshot.identities == @[ident("lib", "1.0.0")]
        check wjCollect in s.w.jobs
        check not dirExists(appDir)
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0404] [PKG-0405] [PKG-0408] update: a newer version swaps in one commit; no newer version answers the current record":
      withStore(
        "update",
        scene([(entryOf("lib", "1.0.0"), lib100), (entryOf("lib", "1.1.0"), lib110)]),
      ):
        s.submit(1, install("lib"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("lib", "1.1.0")
        s.submit(2, remove("lib", "1.1.0"))
        s.w.serve(s.objects, s.calls)
        # 1.0.0 by its version, then the update to 1.1.0
        s.submit(
          3,
          OperationRequest(
            kind: opInstall,
            root: RootReference(package: Opt.some("lib"), version: Opt.some("1.0.0")),
          ),
        )
        s.w.serve(s.objects, s.calls)
        check s.w.e.snapshot.identities == @[ident("lib", "1.0.0")]
        let before = s.w.e.snapshot.sequence
        s.submit(4, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(4).installedIdentity == ident("lib", "1.1.0")
        check s.w.e.snapshot.identities == @[ident("lib", "1.1.0")]
        check s.w.e.snapshot.sequence == before + 1
        s.submit(5, update("lib", "1.1.0"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(5).installedIdentity == ident("lib", "1.1.0")
        check s.w.e.snapshot.sequence == before + 1
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0389] [PKG-0393] [PKG-0394] [PKG-0437] inspect: the root's inspection record, and nothing changes":
      withStore(
        "inspect",
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)]),
      ):
        s.submit(1, inspect("app"))
        s.w.serve(s.objects, s.calls)
        let v = s.encodedOf(1)
        check v.errorCode == ""
        check v.field("inspection").field("manifest").field("package").text == "app"
        # [PKG-0437] The signer its verification established.
        check v.field("inspection").field("signer").field("public_key").bytes == @orgPub
        # [PKG-0394] The verified material kept in the verification cache, and nothing installed.
        check s.w.e.cache.len == 2
        check s.w.e.snapshot.sequence == 0
        check s.w.e.spooled == 0
        s.w.worker.close()
        store.close()

    test "[PKG-0397] [PKG-0398] a failure stops at that package: the dependencies committed before it stay, the root is not installed, and a full disk is package-unavailable":
      withStore(
        "failure",
        scene(
          [
            (entryOf("top", "1.0.0"), top100),
            (entryOf("mid", "1.0.0"), mid100),
            (entryOf("base", "1.0.0"), base100),
          ]
        ),
      ):
        s.w.worker.failStage = "mid"
        s.submit(1, install("top"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(1).errorCode == "package-unavailable"
        check s.w.e.snapshot.identities == @[ident("base", "1.0.0")]
        check s.w.logs.anyIt("No space left on device" in it)
        check s.w.e.spooled == 0
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    proc budgetScene(): Scene =
      let biggest = [top100, mid100, base100].mapIt(it.len).max
      scene(
        [
          (entryOf("top", "1.0.0"), top100),
          (entryOf("mid", "1.0.0"), mid100),
          (entryOf("base", "1.0.0"), base100),
        ],
        limits = Opt.some(LcnPmLimits(archive_bytes: Opt.some(uint64(biggest)))),
        spoolBudgetArchives = 1,
      )

    test "[IMPL-DECISION G446] with a budget of one archive a closure of three installs as with any budget: an evicted archive is fetched again by digest, and each package's spool file goes once its commit returns":
      withStore("budget", budgetScene()):
        s.submit(1, install("top"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("top", "1.0.0")
        check s.w.e.snapshot.identities ==
          @[ident("base", "1.0.0"), ident("mid", "1.0.0"), ident("top", "1.0.0")]
        check s.w.e.spoolEvictions == 1
        check s.calls.countIt(it.kind == cmStat and it.locator == bytesOf("mid@1.0.0")) ==
          2
        check s.w.e.spooled == 0
        check s.w.e.mutationSpoolUsed == 0
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[IMPL-DECISION G446] an evicted archive fetched again with another digest is package-unavailable, and the dependency committed before it stays":
      withStore("budget-digest", budgetScene()):
        s.submit(1, install("top"))
        s.untilStat("base@1.0.0")
        var other = mid100 # the same size, another digest
        other[other.len div 2] = other[other.len div 2] xor 1
        s.objects[bytesOf("mid@1.0.0")] = other
        s.w.serve(s.objects, s.calls)
        check s.resultOf(1).errorCode == "package-unavailable"
        check s.w.logs.anyIt("another digest" in it)
        check s.w.e.snapshot.identities == @[ident("base", "1.0.0")]
        check s.w.e.spooled == 0
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    let libConflict =
      packed(dataManifest("lib", "1.0.0", [("base", "1.0.0")]), "org", orgKey)
      # lib 1.0.0 with another manifest: another commitment
    let lib110b =
      packed(dataManifest("lib", "1.1.0", [("base", "1.0.0")]), "org", orgKey)
    let base101 = packed(dataManifest("base", "1.0.1"), "org", orgKey)
    let libOther110b =
      packed(dataManifest("lib", "1.1.0", [("base", "1.0.0")]), "org2", otherKey)
      # lib110b's manifest, so its commitment, under org2
    let deadlineLimits =
      Opt.some(LcnPmLimits(operation_deadline_ms: Opt.some(1_000'u32)))

    proc installFrom(name, locator: string): OperationRequest =
      OperationRequest(
        kind: opInstall,
        root: RootReference(
          package: Opt.some(name), source: Opt.some(lgxSource("main", locator))
        ),
      )

    proc runUntilCommit(s: var Scene, nth: int) =
      ## With the worker held: answers calls, runs turns and jobs, until the `nth` commit
      ## is the next job.
      var seen = 0
      while true:
        if s.w.work.len > 0:
          if s.w.work[0].kind == wjCommit:
            inc seen
            if seen == nth:
              return
          discard s.w.runOne()
        elif s.w.has({cmStat, cmRead}):
          s.answerOne()
        elif not s.w.turn():
          doAssert false, "no commit " & $nth

    test "[PKG-0608] [PKG-0609] [PKG-0439] [TXT-0495] installing an installed package from a source another accepted signer signed retains that signer: the record's next generation, nothing else changed (PM l.1686-1690)":
      withStore("signer", scene([(entryOf("lib", "1.0.0"), lib100)])):
        s.objects[bytesOf("lib-org2")] = libOther
        s.submit(1, install("lib"))
        s.w.serve(s.objects, s.calls)
        let before = s.w.e.snapshot.records[0]
        s.submit(2, installFrom("lib", "lib-org2"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(2).installedIdentity == ident("lib", "1.0.0")
        let after = s.w.e.snapshot.records[0]
        check after.rid == before.rid
        check after.generation == 2
        check after.package.signer.key == otherPub
        check after.package.signer != before.package.signer
        check after.package.commitment == before.package.commitment
        check after.artifacts == before.artifacts
        check s.w.e.installedChanges == 2
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0608] [PKG-0609] [TXT-0494] [TXT-0495] a signer replacement applies to the identity the request names: its installed dependency keeps its signer and record, and the root's edges stay":
      withStore(
        "signer-deps",
        scene([(entryOf("lib", "1.1.0"), lib110b), (entryOf("base", "1.0.0"), base100)]),
      ):
        s.objects[bytesOf("lib110b-org2")] = libOther110b
        s.submit(1, install("lib"))
        s.w.serve(s.objects, s.calls)
        let before = s.w.e.snapshot
        check before.identities == @[ident("base", "1.0.0"), ident("lib", "1.1.0")]
        s.submit(2, installFrom("lib", "lib110b-org2"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(2).installedIdentity == ident("lib", "1.1.0")
        let after = s.w.e.snapshot
        # One installed-state change, under the mutation slot (PM l.1690).
        check after.sequence == before.sequence + 1
        let (b0, b1) = (
          before.recordOf(ident("base", "1.0.0")),
          after.recordOf(ident("base", "1.0.0")),
        )
        check b1.rid == b0.rid and b1.generation == 1
        check b1.package.signer.key == orgPub
        let (l0, l1) = (
          before.recordOf(ident("lib", "1.1.0")), after.recordOf(ident("lib", "1.1.0"))
        )
        check l1.generation == 2
        check l1.package.signer.key == otherPub
        check l1.package.resolvedDependencies == l0.package.resolvedDependencies
        check l1.artifacts == l0.artifacts
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[IMPL-DECISION G449] installing a package whose identity is installed with another commitment is package-conflict, and nothing changes":
      withStore(
        "conflict",
        scene([(entryOf("lib", "1.0.0"), lib100), (entryOf("base", "1.0.0"), base100)]),
      ):
        s.objects[bytesOf("lib-conflict")] = libConflict
        s.submit(1, install("lib"))
        s.w.serve(s.objects, s.calls)
        s.submit(2, installFrom("lib", "lib-conflict"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(2).errorCode == "package-conflict"
        check s.w.e.snapshot.sequence == 1
        s.w.worker.close()
        store.close()

    test "[IMPL-DECISION G449] a deadline or a cancel inside the root's commit does not apply: the commit completes, and the answer is the record (Fable's §4)":
      withStore(
        "lastcommit", scene([(entryOf("lib", "1.0.0"), lib100)], deadlineLimits)
      ):
        s.w.holdWork = true
        s.submit(1, install("lib"))
        s.runUntilCommit(1)
        s.w.handle(fired(s.w.timerFor(1_000)))
        s.w.emit(s.w.e.cancel(1))
        check s.answerOf(1).isNone
        s.w.holdWork = false
        s.w.runWork()
        check s.encodedOf(1).installedIdentity == ident("lib", "1.0.0")
        check s.w.e.snapshot.identities == @[ident("lib", "1.0.0")]
        s.w.worker.close()
        store.close()

    test "[PKG-0398] [IMPL-DECISION G449] a deadline inside a dependency's commit is package-unavailable, with that dependency installed":
      withStore(
        "depcommit",
        scene(
          [(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)],
          deadlineLimits,
        ),
      ):
        s.w.holdWork = true
        s.submit(1, install("app"))
        s.runUntilCommit(1)
        s.w.handle(fired(s.w.timerFor(1_000)))
        check s.resultOf(1).errorCode == "package-unavailable"
        s.w.holdWork = false
        s.w.runWork()
        check s.w.e.snapshot.identities == @[ident("lib", "1.0.0")]
        check s.w.e.spooled == 0
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[IMPL-DECISION G449] a removal during an inspection does not fail it: the removed record's directory stays until the inspection ends (R1)":
      withStore(
        "r1",
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)]),
      ):
        s.submit(1, install("app"))
        s.w.serve(s.objects, s.calls)
        let appDir = s.w.e.snapshot.records[0].base.parentDir
        s.submit(2, inspect("app")) # waits on its retrievals, unanswered
        s.submit(3, remove("app", "1.0.0"))
        check s.resultOf(3) == removedResult()
        check dirExists(appDir)
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(2).errorCode == ""
        check not dirExists(appDir)
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

      # lib 1.1.0 with another manifest: another commitment than lib110's
    let noOrg2 = trustOf(
      [anchorOf("org", ["app", "base", "lib", "logos.example", "mid", "top"], orgPub)]
    ).trustBytes # org2 withdrawn

    template restartWith(made: Scene) {.dirty.} =
      ## The next start over the same installed state: the worker's half and the lock
      ## released, the store opened again under the new scene's input.
      s.w.worker.close()
      store.close()
      store = openStore(dir).get
      s = made
      s.w.attachStore(store)

    test "[PKG-0080] [PKG-0440] [PKG-0608] [TXT-0493] C6 (G166): with the retained signer withdrawn and no accepted source, install and update fail signature-verification-failed; once the catalog lists an accepted archive, the install replaces the signer":
      withStore(
        "c6", scene([(entryOf("lib", "1.0.0", locator = "lib-org2"), libOther)])
      ):
        s.submit(1, install("lib"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("lib", "1.0.0")
        check s.w.e.snapshot.records[0].package.signer.key == otherPub
        # The next start under a trust that no longer has org2.
        restartWith(
          scene(
            [(entryOf("lib", "1.0.0", locator = "lib-org2"), libOther)], trust = noOrg2
          )
        )
        s.submit(2, install("lib"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(2).errorCode == "signature-verification-failed"
        s.submit(3, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(3).errorCode == "signature-verification-failed"
        check s.w.e.snapshot.sequence == 1
        # The catalog lists an archive org signed: the install retains org (PKG-0608).
        restartWith(scene([(entryOf("lib", "1.0.0"), lib100)], trust = noOrg2))
        s.submit(4, install("lib"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(4).installedIdentity == ident("lib", "1.0.0")
        let r = s.w.e.snapshot.records[0]
        check r.generation == 2
        check r.package.signer.key == orgPub
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[IMPL-DECISION G449] PM l.1331: an installed record's retained source that the catalog does not list is never selected":
      # `lib-org2` sorts before `lib@1.0.0`, so it would be the source selected, were it
      # acceptable.
      withStore("retained-source", scene([(entryOf("lib", "1.0.0"), lib100)])):
        s.objects[bytesOf("lib-org2")] = libOther
        s.submit(1, installFrom("lib", "lib-org2"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("lib", "1.0.0")
        proc retainedStats(s: Scene): int =
          s.calls.countIt(it.kind == cmStat and it.locator == bytesOf("lib-org2"))

        check s.retainedStats == 1
        s.submit(2, install("lib"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(2).installedIdentity == ident("lib", "1.0.0")
        check s.retainedStats == 1
        s.submit(3, inspect("lib"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(3).errorCode == ""
        check s.retainedStats == 1
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0406] [PKG-0534] [PKG-0537] update: an absent current is package-not-installed; a target installed with another commitment is package-conflict; one with the same commitment and equal edges drops the current in one commit and answers the target":
      withStore(
        "update-cases",
        scene(
          [
            (entryOf("lib", "1.0.0"), lib100),
            (entryOf("lib", "1.1.0"), lib110),
            (entryOf("base", "1.0.0"), base100),
          ]
        ),
      ):
        s.objects[bytesOf("lib110b")] = lib110b
        s.submit(1, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(1).errorCode == "package-not-installed"
        s.submit(2, installVersion("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        s.submit(3, installFrom("lib", "lib110b"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(3).installedIdentity == ident("lib", "1.1.0")
        let before = s.w.e.snapshot.sequence
        s.submit(4, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(4).errorCode == "package-conflict"
        check s.w.e.snapshot.sequence == before
        # lib 1.1.0 again, from the catalog: the commitment the update selects.
        s.submit(5, remove("lib", "1.1.0"))
        s.w.serve(s.objects, s.calls)
        s.submit(6, installVersion("lib", "1.1.0"))
        s.w.serve(s.objects, s.calls)
        let after = s.w.e.snapshot.sequence
        let target = s.w.e.snapshot.recordOf(ident("lib", "1.1.0"))
        s.submit(7, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(7).installedIdentity == ident("lib", "1.1.0")
        check s.w.e.snapshot.identities ==
          @[ident("base", "1.0.0"), ident("lib", "1.1.0")]
        check s.w.e.snapshot.sequence == after + 1
        let kept = s.w.e.snapshot.recordOf(ident("lib", "1.1.0"))
        check kept.rid == target.rid and kept.generation == target.generation
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0407] update: a failure keeps the current root":
      withStore(
        "update-fail",
        scene([(entryOf("lib", "1.0.0"), lib100), (entryOf("lib", "1.1.0"), lib110)]),
      ):
        s.submit(1, installVersion("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        s.w.worker.failStage = "lib"
        s.submit(2, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(2).errorCode == "package-unavailable"
        check s.w.e.snapshot.identities == @[ident("lib", "1.0.0")]
        check s.w.e.spooled == 0
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0535] [PKG-0536] update: a target installed with the same commitment but other recorded dependencies than the ones selected now is dependency-unavailable, and nothing changes (PKG-0536)":
      withStore(
        "update-edges",
        scene(
          [
            (entryOf("lib", "1.0.0"), lib100),
            (entryOf("lib", "1.1.0"), lib110b),
            (entryOf("base", "1.0.0"), base100),
          ]
        ),
      ):
        s.submit(1, installVersion("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        s.submit(2, installVersion("lib", "1.1.0"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(2).installedIdentity == ident("lib", "1.1.0")
        # lib 1.1.0 records its edge to base 1.0.0. The next start's catalog lists base
        # 1.0.1, which lib's `compatible` requirement now selects first.
        restartWith(
          scene(
            [
              (entryOf("lib", "1.0.0"), lib100),
              (entryOf("lib", "1.1.0"), lib110b),
              (entryOf("base", "1.0.0"), base100),
              (entryOf("base", "1.0.1"), base101),
            ]
          )
        )
        let before = s.w.e.snapshot.sequence
        s.submit(3, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(3).errorCode == "dependency-unavailable"
        check "records other dependencies" in s.resultOf(3).errorMessage
        check s.w.e.snapshot.sequence == before
        check s.w.e.snapshot.identities ==
          @[ident("base", "1.0.0"), ident("lib", "1.0.0"), ident("lib", "1.1.0")]
        check s.w.e.spooled == 0
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0410] an inspection during a mutation sees the earlier snapshot, and after the commit the later one":
      withStore("inspect-during", scene([(entryOf("lib", "1.0.0"), lib100)])):
        s.w.holdWork = true
        s.submit(1, install("lib"))
        s.runUntilCommit(1)
        s.submit(2, inspect("lib")) # takes its slot over sequence 0
        check s.w.e.heldSnapshots == 2
        s.w.holdWork = false
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("lib", "1.0.0")
        check s.encodedOf(2).errorCode == ""
        # lib was not installed in its snapshot: no retained bytes were checked.
        check wjRetained notin s.w.jobs
        s.submit(3, inspect("lib"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(3).errorCode == ""
        # In the later one it is: its retained bytes are hashed before it is used.
        check s.w.jobs.countIt(it == wjRetained) == 1
        check s.w.e.heldSnapshots == 0
        s.w.worker.close()
        store.close()

    test "[PKG-0470] an admission failure is MODULE_ERROR, and nothing is committed":
      withStore("admission", scene([(entryOf("lib", "1.0.0"), lib100)])):
        admissionLimitForTests = 64
        defer:
          admissionLimitForTests = 0
        s.submit(1, install("lib"))
        s.w.serve(s.objects, s.calls)
        let a = s.answerOf(1)
        check a.isSome and a.get.kind == oaModuleError
        check s.w.e.snapshot.sequence == 0
        check toSeq(walkDir(dir / "install" / "r")).len == 0
        check s.w.e.spooled == 0
        let live = s.w.e.snapshot
        check sameRecords(live, s.diskSnapshot(store, dir))

    test "[PKG-0190] a nix source is unsupported-source":
      var s = scene([(entryOf("lib", "1.0.0"), lib100)])
      s.submit(
        1,
        OperationRequest(
          kind: opInstall,
          root: RootReference(
            source:
              Opt.some(PackageSource(kind: skNix, flakeRef: "github:example/flake"))
          ),
        ),
      )
      s.w.serve(s.objects, s.calls)
      check s.resultOf(1).errorCode == "unsupported-source"

    test "[PKG-0390] [PKG-0391] [PKG-0392] [PKG-0403] the request's root: neither package nor source, or a version without package, is invalid-request; a source whose manifest names another package is invalid-package; nothing changes":
      withStore(
        "requests",
        scene([(entryOf("lib", "1.0.0"), lib100), (entryOf("lib", "1.1.0"), lib110)]),
      ):
        s.submit(1, OperationRequest(kind: opInspect, root: RootReference()))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(1).errorCode == "invalid-request"
        s.submit(
          2,
          OperationRequest(
            kind: opInspect,
            root: RootReference(
              version: Opt.some("1.0.0"),
              source: Opt.some(lgxSource("main", "lib@1.0.0")),
            ),
          ),
        )
        s.w.serve(s.objects, s.calls)
        check s.resultOf(2).errorCode == "invalid-request"
        s.submit(3, installFrom("app", "lib@1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(3).errorCode == "invalid-package"
        s.submit(4, installVersion("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        # update_package to 1.1.0 from a source whose manifest is lib 1.0.0 (PM l.1703).
        s.submit(
          5,
          OperationRequest(
            kind: opUpdate,
            root: RootReference(
              package: Opt.some("lib"),
              version: Opt.some("1.1.0"),
              newerThan: Opt.some(ident("lib", "1.0.0")),
              source: Opt.some(lgxSource("main", "lib@1.0.0")),
            ),
          ),
        )
        s.w.serve(s.objects, s.calls)
        check s.resultOf(5).errorCode == "invalid-package"
        check s.w.e.snapshot.identities == @[ident("lib", "1.0.0")]
        check s.w.e.snapshot.sequence == 1
        s.w.worker.close()
        store.close()

    test "[PKG-0360] messages hold no state directory or path; the operator's log does (PKG-0360)":
      withStore(
        "SENTINEL-STATE-DIR",
        scene(
          [
            (entryOf("top", "1.0.0"), top100),
            (entryOf("mid", "1.0.0"), mid100),
            (entryOf("base", "1.0.0"), base100),
            (entryOf("lib", "1.0.0"), lib100),
          ]
        ),
      ):
        s.objects[bytesOf("lib-conflict")] = libConflict
        s.w.worker.failStage = "mid"
        s.submit(1, install("top"))
        s.w.serve(s.objects, s.calls)
        s.submit(2, install("lib"))
        s.w.serve(s.objects, s.calls)
        s.submit(3, installFrom("lib", "lib-conflict"))
        s.w.serve(s.objects, s.calls)
        s.submit(4, remove("base", "1.0.0"))
        s.submit(5, update("lib", "1.0.0"))
        s.w.serve(s.objects, s.calls)
        check s.w.answers.len == 5
        var errors = 0
        for c in s.w.answers:
          # A success's record names its artifacts' `local_path`s by design (PM §10); a
          # message names none.
          let text =
            case c.answer.kind
            of oaModuleError:
              c.answer.reason
            else:
              let v =
                if c.answer.kind == oaEncoded:
                  decodeCbor(c.answer.encoded).get
                else:
                  c.answer.response
              if v.errorCode.len > 0:
                inc errors
              let m = v.field("error").field("message")
              m.getText.get("")
          check "SENTINEL" notin text
        check errors == 2 # the full disk and the conflict
        check s.w.logs.anyIt("SENTINEL-STATE-DIR" in it)
        s.w.worker.close()
        store.close()

    test "[IMPL-DECISION G449] a handoff is built on the worker from the record's directory, a query that takes no slot; a module not selected and a package not installed are refused":
      withStore("handoff", scene([(entryOf("logos.example", "1.0.0"), exampleBytes)])):
        s.submit(1, install("logos.example"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("logos.example", "1.0.0")
        let id = ident("logos.example", "1.0.0")
        s.w.emit(s.w.e.handoff(2, id, "alpha_module"))
        let h = s.encodedOf(2)
        check h.errorCode == ""
        check h.field("handoff").kind == ckMap
        check s.w.e.slotRunning(slMutation).isNone
        s.w.emit(s.w.e.handoff(3, id, "no_such_module"))
        check s.encodedOf(3).errorCode == "invalid-request"
        s.w.emit(s.w.e.handoff(4, ident("logos.example", "9.9.9"), "alpha_module"))
        check s.resultOf(4).errorCode == "package-not-installed"
        check s.w.e.heldSnapshots == 0
        s.w.worker.close()
        store.close()

# The engine's page jobs (5-6b-1) ----------------------------------------------------------

# Off POSIX the engine answers a page job or a reader's handoff MODULE_ERROR (the installed
# state is POSIX only), so the cases that reach one skip there; the limit check runs everywhere.
suite "the engine's page jobs (5-6b-1; G499, G500)":
  let
    a = Origin(runtime: "rt", instance: "a")
    b = Origin(runtime: "rt", instance: "b")

  proc record(package, version: string, rid: string): SnapRecord =
    var c = ManifestCommitment(commitmentModel: "m", hashProfile: "p", hashSuite: "s")
    c.valueRoot[0] = byte(rid.len)
    SnapRecord(
      package: InstalledPackage(
        identity: PackageIdentity(package: package, version: version), commitment: c
      ),
      rid: rid,
      generation: 1,
    )

  proc pageOf(a: Command): CborValue =
    ## A `cmAnswer`'s page, decoded.
    doAssert a.kind == cmAnswer and a.answer.kind == oaEncoded, $a.kind
    let bytes = a.answer.encoded
    decodeCbor(bytes.toOpenArrayByte(0, bytes.high)).get

  func codeOf(a: Command): string =
    ## The answer's `package_error` code; empty for any other answer.
    if a.kind == cmAnswer and a.answer.kind == oaResponse:
      let e = a.answer.response.lookup("error")
      if e.isSome:
        return e.get.lookup("code").get(cbor("")).getText.get("")

  proc world(): World =
    result = newWorld(catalogBytes(@[entryOf("app", "1.0.0")]))
    result.emit(result.e.start())
    result.e.setSnapshot(
      Snapshot(
        sequence: 1,
        records: @[
          record("app", "1.0.0", "r1"),
          record("lib", "1.2.0", "r2"),
          record("lib", "1.3.0", "r3"),
        ],
      )
    )

  proc last(w: var World): Command =
    w.answers[^1]

  test "[PKG-0558] [IMPL-DECISION G500] page jobs: 2 in flight per origin and 8 in all, readers' handoffs among them; past either bound MODULE_ERROR naming it; a cancel frees its place once the job has ended":
    when not defined(posix):
      skip()
      break
    var w = world()
    var id = 0'u64
    proc list(w: var World, o: Origin): uint64 =
      inc id
      w.emit(
        w.e.listInstalled(id, o, Opt.none(string), Opt.none(string), Opt.none(uint16))
      )
      id

    discard w.list(a)
    discard w.list(a)
    check w.count({cmPage}) == 2
    discard w.list(a)
    check w.last.answer.kind == oaModuleError
    check "2 in flight for this caller" in w.last.answer.reason
    for i in 0 ..< 3:
      let o = Origin(runtime: "rt", instance: "o" & $i)
      discard w.list(o)
      inc id
      w.emit(
        w.e.readerHandoff(id, o, PackageIdentity(package: "app", version: "1.0.0"), "m")
      )
    check w.e.pagesRunning == 8
    check w.count({cmPage}) == 8
    let held = w.e.heldSnapshots
    let n = w.answers.len
    discard w.list(b)
    check w.answers.len == n + 1
    check w.last.answer.kind == oaModuleError
    check "8 in flight in all" in w.last.answer.reason
    # A reader's handoff is refused at the bound too, and never reaches the first worker.
    inc id
    w.emit(
      w.e.readerHandoff(id, b, PackageIdentity(package: "app", version: "1.0.0"), "m")
    )
    check w.last.answer.kind == oaModuleError
    # Readers' handoffs went to the read-only worker, none to the first.
    check w.queue.filterIt(it.kind == cmPage).countIt(it.job.kind == wjReaderHandoff) ==
      3
    # [Fable §17.3 point 1] A cancel: the job still runs on the read-only worker, so it
    # keeps its place and its snapshot, and the bound still refuses.
    w.emit(w.e.cancel(1))
    check w.e.pagesRunning == 8
    check w.e.heldSnapshots == held
    discard w.list(b)
    check w.last.answer.kind == oaModuleError
    check "8 in flight in all" in w.last.answer.reason
    # The worker answers it: nothing is answered for it, and its place is free.
    let job = w.take({cmPage})
    check job.job.request == 1
    let n2 = w.answers.len
    w.handle(
      worked(
        WorkerResult(
          kind: wrPage, request: 1, count: 1, reply: textOf(encodeCbor(cbor(1'u64)))
        )
      )
    )
    check w.answers.len == n2
    check w.e.pagesRunning == 7
    check w.e.heldSnapshots == held - 1
    discard w.list(b)
    check w.e.pagesRunning == 8

  test "[PKG-0558] [IMPL-DECISION G500] a reader that lists and cancels in a loop is refused once its places are full, and the read-only worker's queue holds no more of its jobs than its places":
    when not defined(posix):
      skip()
      break
    var w = world()
    var queued: seq[uint64]
    var refused = 0
    for id in 1'u64 .. 10'u64:
      let n = w.count({cmPage})
      w.emit(
        w.e.listInstalled(id, a, Opt.none(string), Opt.none(string), Opt.none(uint16))
      )
      if w.count({cmPage}) > n:
        queued.add(id)
      else:
        check w.last.answer.kind == oaModuleError
        check "2 in flight for this caller" in w.last.answer.reason
        inc refused
      w.emit(w.e.cancel(id))
    check queued == @[1'u64, 2]
    check refused == 8
    check w.count({cmPage}) == PagesPerOrigin
    check w.e.pagesRunning == PagesPerOrigin
    # The worker answers the first: dropped, and one place is free for the next list.
    discard w.take({cmPage})
    let n = w.answers.len
    w.handle(
      worked(
        WorkerResult(
          kind: wrPage, request: 1, count: 1, reply: textOf(encodeCbor(cbor(1'u64)))
        )
      )
    )
    check w.answers.len == n
    check w.e.pagesRunning == 1
    w.emit(
      w.e.listInstalled(11, a, Opt.none(string), Opt.none(string), Opt.none(uint16))
    )
    check w.e.pagesRunning == 2
    check w.count({cmPage}) == 2
    check w.e.heldSnapshots == 2

  test "[PKG-0533] [PKG-0384] [PKG-0387] [IMPL-DECISION G499] [IMPL-DECISION G500] a page's answer: next_cursor exactly when a matching record remains; its continuation goes on; after a commit it is invalid-request":
    when not defined(posix):
      skip()
      break
    var w = world()
    w.emit(w.e.listInstalled(1, a, Opt.some("lib"), Opt.none(string), Opt.some(1'u16)))
    let job = w.take({cmPage}).job
    check job.kind == wjPage
    check job.page.mapIt(it.identity.version) == @["1.3.0"]
    w.handle(
      worked(
        WorkerResult(
          kind: wrPage, request: 1, count: 1, reply: textOf(encodeCbor(cbor(3'u64)))
        )
      )
    )
    let first = w.answers[^1].pageOf
    check first.lookup("packages").get.items == @[cbor(3'u64)]
    let token = first.lookup("next_cursor").get.getText.get
    check w.e.cursorsHeld == 1
    check w.e.heldSnapshots == 0
    # The continuation: the last lib, then no cursor.
    w.emit(w.e.listInstalled(2, a, Opt.some("lib"), Opt.some(token), Opt.some(1'u16)))
    let job2 = w.take({cmPage}).job
    check job2.page.mapIt(it.identity.version) == @["1.2.0"]
    w.handle(
      worked(
        WorkerResult(
          kind: wrPage, request: 2, count: 1, reply: textOf(encodeCbor(cbor(2'u64)))
        )
      )
    )
    check w.answers[^1].pageOf.lookup("next_cursor").isNone
    check w.e.cursorsHeld == 0
    # Another origin, the same token: invalid-request, and nothing more said.
    w.emit(w.e.listInstalled(3, a, Opt.none(string), Opt.none(string), Opt.some(1'u16)))
    discard w.take({cmPage})
    w.handle(
      worked(
        WorkerResult(
          kind: wrPage, request: 3, count: 1, reply: textOf(encodeCbor(cbor(1'u64)))
        )
      )
    )
    let t3 = w.answers[^1].pageOf.lookup("next_cursor").get.getText.get
    w.emit(w.e.listInstalled(4, b, Opt.none(string), Opt.some(t3), Opt.some(1'u16)))
    check w.answers[^1].codeOf == "invalid-request"
    # A commit supersedes the snapshot: the cursor has expired.
    w.e.setSnapshot(Snapshot(sequence: 2, records: @[record("app", "1.0.0", "r1")]))
    w.emit(w.e.listInstalled(5, a, Opt.none(string), Opt.some(t3), Opt.some(1'u16)))
    check w.answers[^1].codeOf == "invalid-request"
    check w.e.cursorsHeld == 0

  test "[PKG-0387] [IMPL-DECISION G499] the 1 s timer reclaims expired cursors while any is held":
    when not defined(posix):
      skip()
      break
    var w = world()
    w.emit(w.e.listInstalled(1, a, Opt.none(string), Opt.none(string), Opt.some(1'u16)))
    discard w.take({cmPage})
    w.handle(
      worked(
        WorkerResult(
          kind: wrPage, request: 1, count: 1, reply: textOf(encodeCbor(cbor(1'u64)))
        )
      )
    )
    check w.e.cursorsHeld == 1
    let t = w.timerFor(1000)
    w.clock.ms = IdleMs
    w.handle(fired(t))
    check w.e.cursorsHeld == 0
    check not w.has({cmTimer})

  test "[SPEC PM l.1640-1641] a list's limit outside 1 to 1000 is invalid-request, before anything is read":
    var w = world()
    w.emit(w.e.listInstalled(1, a, Opt.none(string), Opt.none(string), Opt.some(0'u16)))
    check w.answers[^1].codeOf == "invalid-request"
    w.emit(
      w.e.listInstalled(2, a, Opt.none(string), Opt.none(string), Opt.some(1001'u16))
    )
    check w.answers[^1].codeOf == "invalid-request"
    check not w.has({cmPage})

# The watch's hints and the operations' progress (5-6b-2) -------------------------------

when defined(posix):
  proc progressOf(s: Scene, request: uint64): seq[Command] =
    s.w.queue.filterIt(it.kind == cmProgress and it.progressOf == request)

  proc changed(s: Scene): int =
    s.w.queue.countIt(it.kind == cmChanged)

  suite "the watch's hints and the operations' progress (5-6b-2; G501, G502)":
    test "[PKG-0564] [PKG-0568] [PKG-0569] [PKG-0570] [TXT-0497] [TXT-0498] [IMPL-DECISION G502] an install submitted with progress reports resolving first, then for each archive fetching (bytes read of the size stat_object gave), verifying (none, then all of its bytes) and installing (no counters); one submitted without reports nothing; [IMPL-DECISION G501] each landed commit is one cmChanged, and a no-op none":
      withStore(
        "progress",
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)]),
      ):
        s.w.emit(s.w.e.submit(1, install("app"), progress = true))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(1).installedIdentity == ident("app", "1.0.0")
        let p = s.progressOf(1)
        checkpoint $p.mapIt((it.phase, it.completed, it.total))
        check p.len > 0
        if p.len > 0:
          check p[0].phase == ppResolving
          check p[0].completed.isNone and p[0].total.isNone
        check p.allIt(it.phase in {ppResolving, ppFetching, ppVerifying, ppInstalling})
        check p.countIt(it.phase == ppResolving) == 1
        let sizes = [uint64(app100.len), uint64(lib100.len)]
        let fetching = p.filterIt(it.phase == ppFetching)
        check fetching.len >= 2
        check fetching.allIt(
          it.completed.isSome and it.total.isSome and it.total.get in sizes and
            it.completed.get <= it.total.get
        )
        let verifying = p.filterIt(it.phase == ppVerifying)
        check verifying.len == 4
        for size in sizes:
          check fetching.anyIt(it.total.get == size and it.completed.get == size)
          check verifying.anyIt(
            it.completed == Opt.some(0'u64) and it.total == Opt.some(size)
          )
          check verifying.anyIt(
            it.completed == Opt.some(size) and it.total == Opt.some(size)
          )
        let installing = p.filterIt(it.phase == ppInstalling)
        check installing.len == 2
        check installing.allIt(it.completed.isNone and it.total.isNone)
        check s.changed == 2
        s.submit(2, install("app"))
        s.w.serve(s.objects, s.calls)
        check s.encodedOf(2).installedIdentity == ident("app", "1.0.0")
        check s.progressOf(2).len == 0
        check s.changed == 2
        store.close()

    test "[PKG-0564] [PKG-0568] [TXT-0498] [IMPL-DECISION G502] a remove submitted with progress reports removing, with no counters; [IMPL-DECISION G501] its commit is one cmChanged, and a remove of what is not installed none":
      withStore(
        "progress-remove",
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)]),
      ):
        s.submit(1, install("app"))
        s.w.serve(s.objects, s.calls)
        check s.changed == 2
        s.w.emit(s.w.e.submit(2, remove("app", "1.0.0"), progress = true))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(2).errorCode == ""
        let p = s.progressOf(2)
        check p.mapIt(it.phase) == @[ppRemoving]
        check p.allIt(it.completed.isNone and it.total.isNone)
        check s.changed == 3
        s.w.emit(s.w.e.submit(3, remove("app", "1.0.0"), progress = true))
        s.w.serve(s.objects, s.calls)
        check s.resultOf(3).errorCode == ""
        check s.progressOf(3).len == 0
        check s.changed == 3
        store.close()

    test "[IMPL-DECISION G502] a cancelled operation reports nothing more":
      withStore(
        "progress-cancel",
        scene([(entryOf("app", "1.0.0"), app100), (entryOf("lib", "1.0.0"), lib100)]),
      ):
        s.w.emit(s.w.e.submit(1, install("app"), progress = true))
        let before = s.progressOf(1).len
        check before >= 1
        s.w.emit(s.w.e.cancel(1))
        s.w.serve(s.objects, s.calls)
        check s.progressOf(1).len == before
        check s.changed == 0
        store.close()
